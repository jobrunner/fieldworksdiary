// Package enrichment runs after a sample is inserted (or its coordinate
// changes), querying Ortus in a background goroutine and writing the
// place, features, MTB and terrain values back to the sample. Failures
// here MUST NEVER affect the originating sample save — that's already
// committed by the time we run.
package enrichment

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"runtime/debug"
	"strings"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/geoplace"
	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
)

// location_status values of a sample.
const (
	statusBackendService = "backend_service"
	statusInherited      = "inherited"
	statusManual         = "manual"
	statusPending        = "pending"
)

// coordEpsilon is the smallest latitude/longitude change (degrees) that
// re-triggers the enrichment on update; below it is float noise from the
// 6-decimal round trip.
const coordEpsilon = 1e-7

// Enricher fills placemark, features, MTB and terrain values on an
// already-saved sample. Construct one at startup, register the hooks,
// then leave it.
//
// `App` ist absichtlich auf `core.App` getypt (Interface), damit Tests
// `tests.TestApp` direkt einsetzen können — `*pocketbase.PocketBase`
// implementiert das Interface via eingebettetem `*core.BaseApp` ebenso.
type Enricher struct {
	App core.App
	// Ortus is the geo service. Nil disables the location enrichment;
	// the fieldtrip-derived fields are still recomputed.
	Ortus *services.Ortus
	// Labels maps Ortus admin levels onto place columns. Nil falls back
	// to adminlabels.Default().
	Labels *adminlabels.Table
	Logger *slog.Logger
	// Timeout caps the entire enrichment work for one sample.
	Timeout time.Duration
}

// Register wires the after-create and after-update hooks on samples.
// The hooks fire the enrichment in a goroutine so PocketBase's response
// is never blocked on the upstream service. Updates only re-trigger when
// the coordinate moved.
func (e *Enricher) Register() {
	e.App.OnRecordAfterCreateRequest("samples").Add(func(ev *core.RecordCreateEvent) error {
		go e.runSafely(ev.Record.Id, ev.Record.GetString("fieldtrip"))
		return nil
	})
	e.App.OnRecordAfterUpdateRequest("samples").Add(func(ev *core.RecordUpdateEvent) error {
		if !coordChanged(ev.Record) {
			return nil
		}
		go e.runSafely(ev.Record.Id, ev.Record.GetString("fieldtrip"))
		return nil
	})
}

// coordChanged reports whether latitude or longitude of rec differ from
// its original copy by more than coordEpsilon.
func coordChanged(rec *models.Record) bool {
	orig := rec.OriginalCopy()
	return math.Abs(rec.GetFloat("latitude")-orig.GetFloat("latitude")) > coordEpsilon ||
		math.Abs(rec.GetFloat("longitude")-orig.GetFloat("longitude")) > coordEpsilon
}

func (e *Enricher) runSafely(sampleID, ftID string) {
	defer func() {
		if r := recover(); r != nil {
			e.log().Error(
				"enrichment panic",
				slog.String("sample_id", sampleID),
				slog.Any("recover", r),
				slog.String("stack", string(debug.Stack())),
			)
		}
	}()

	timeout := e.Timeout
	if timeout == 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// 1. Sample location enrichment via Ortus.
	e.run(ctx, sampleID)

	// 2. Fieldtrip derived fields (centroid, astro, suggested
	//    locality). Purely local, cheap.
	if ftID != "" {
		e.recomputeFieldtripDerived(ftID)
	}
}

// run queries Ortus for the sample's coordinate and writes the result
// following the location_status rules:
//
//   - no coordinate or status backend_service: nothing to do
//   - Ortus error: sample stays unchanged
//   - no place in the answer (open sea): status stays, geo + features only
//   - pending/inherited (empty counts as pending): shared backend_service
//     placemark, status becomes backend_service
//   - manual: placemark stays; a differing Ortus place is offered as
//     placemark_suggestion
//
// Geo values and features are always replaced; the DEM height is used
// only when the sample has no height of its own (see applyDEMHeight).
// Every write bumps the sample's version.
func (e *Enricher) run(ctx context.Context, sampleID string) {
	log := e.log().With(slog.String("sample_id", sampleID))
	dao := e.App.Dao()
	rec, err := dao.FindRecordById("samples", sampleID)
	if err != nil {
		log.Warn("enrichment: sample disappeared", slog.Any("err", err))
		return
	}
	lat, lon := rec.GetFloat("latitude"), rec.GetFloat("longitude")
	if (lat == 0 && lon == 0) || locationStatus(rec) == statusBackendService || e.Ortus == nil {
		return
	}

	resp, err := e.Ortus.Query(ctx, lat, lon)
	if err != nil {
		log.Warn("enrichment: ortus query failed",
			slog.String("service", "ortus"),
			slog.Any("err", err),
		)
		return
	}

	labels := e.Labels
	if labels == nil {
		labels = adminlabels.Default()
	}
	res := geoplace.FromOrtus(resp, lat, lon, labels)

	// Re-read, mutate and save in one transaction (no network inside),
	// so a client request landing in between is not clobbered.
	var finalStatus string
	err = dao.RunInTransaction(func(tx *daos.Dao) error {
		rec, err := tx.FindRecordById("samples", sampleID)
		if err != nil {
			return fmt.Errorf("sample disappeared: %w", err)
		}
		// A coordinate moved while we waited on Ortus has its own run
		// queued by the update hook.
		if math.Abs(rec.GetFloat("latitude")-lat) > coordEpsilon ||
			math.Abs(rec.GetFloat("longitude")-lon) > coordEpsilon {
			return errSkip
		}
		status := locationStatus(rec)
		if status == statusBackendService {
			return errSkip
		}

		if res.Place != nil {
			switch status {
			case statusPending, statusInherited:
				pm, err := geoplace.LookupOrCreatePlacemark(tx, *res.Place, statusBackendService, "")
				if err != nil {
					return fmt.Errorf("placemark lookup: %w", err)
				}
				rec.Set("placemark", pm.Id)
				rec.Set("placemark_suggestion", "")
				rec.Set("location_status", statusBackendService)
			case statusManual:
				cand, err := geoplace.LookupOrCreatePlacemark(tx, *res.Place, statusBackendService, "")
				if err != nil {
					return fmt.Errorf("placemark lookup: %w", err)
				}
				if res.Place.DedupHash() != currentPlacemarkHash(tx, rec) {
					rec.Set("placemark_suggestion", cand.Id)
				} else {
					rec.Set("placemark_suggestion", "")
				}
			}
		}

		geoplace.ApplyGeo(rec, res.Geo)
		applyDEMHeight(rec, res.Geo)

		// Bump the optimistic-concurrency counter like the version
		// guard (hooks/version_conflict.go) does for client writes, so
		// a client still holding the old version gets 409 instead of
		// silently reverting the enrichment.
		rec.Set("version", rec.GetInt("version")+1)

		if err := tx.SaveRecord(rec); err != nil {
			return fmt.Errorf("save sample: %w", err)
		}
		if err := geoplace.ReplaceFeatures(tx, sampleID, rec.GetString("owner"), res.Features); err != nil {
			return fmt.Errorf("replace features: %w", err)
		}
		finalStatus = rec.GetString("location_status")
		return nil
	})
	switch {
	case errors.Is(err, errSkip):
		log.Debug("enrichment: sample changed during query, skipping")
		return
	case err != nil:
		log.Warn("enrichment: write failed", slog.Any("err", err))
		return
	}
	log.Info("enrichment: sample enriched",
		slog.String("service", "ortus"),
		slog.String("location_status", finalStatus),
		slog.Int("features", len(res.Features)),
	)
}

// errSkip aborts the write transaction without logging a failure.
var errSkip = errors.New("enrichment: skip")

// applyDEMHeight writes the Ortus DEM height when the sample has no
// height of its own: no elevation source, or a previous DEM height
// (backend_service), which derives from the coordinate. GPS
// (location_service) and manual heights are never replaced.
func applyDEMHeight(rec *models.Record, g geoplace.SampleGeo) {
	if g.ElevationDEM == nil {
		return
	}
	switch rec.GetString("elevation_source") {
	case "", "backend_service":
	default:
		return
	}
	rec.Set("elevation", *g.ElevationDEM)
	rec.Set("elevation_source", "backend_service")
	if g.ElevationDEMAccuracy != nil {
		rec.Set("vertical_accuracy", *g.ElevationDEMAccuracy)
	} else {
		rec.Set("vertical_accuracy", 0)
	}
}

// currentPlacemarkHash returns the dedup hash of the sample's current
// placemark, or "" when it has none.
func currentPlacemarkHash(dao *daos.Dao, rec *models.Record) string {
	id := rec.GetString("placemark")
	if id == "" {
		return ""
	}
	pm, err := dao.FindRecordById("placemarks", id)
	if err != nil {
		return ""
	}
	return geoplace.PlaceFromRecord(pm).DedupHash()
}

// locationStatus returns the sample's location_status; empty counts as
// pending.
func locationStatus(rec *models.Record) string {
	if s := strings.TrimSpace(rec.GetString("location_status")); s != "" {
		return s
	}
	return statusPending
}

func (e *Enricher) log() *slog.Logger {
	if e.Logger != nil {
		return e.Logger
	}
	return e.App.Logger()
}
