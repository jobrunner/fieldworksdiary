// Backend-driven reverse geocoding for localities.
//
// Clients never geocode themselves: the backend asks Ortus for the
// place at the locality's coordinate, the shared geoplace helpers
// map it onto a row in the deduplicated `placemarks` collection (the
// same row a sample at that place gets), and the locality holds a
// single-relation `placemark` pointer.
package enrichment

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"runtime/debug"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/fusion"
	"go.mett.io/fwd-backend/internal/geoplace"
	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/pocketbase/core"
)

// PlacemarkEnricher reverse-geocodes a locality's coordinate and
// attaches the resulting Placemark. Construct one at startup, hand
// it to `RegisterPlacemarkEnricher`.
type PlacemarkEnricher struct {
	App core.App
	// Ortus is the geo service. Nil disables the enrichment.
	Ortus *services.Ortus
	// Labels maps Ortus admin levels onto place columns. Nil falls
	// back to adminlabels.Default().
	Labels  *adminlabels.Table
	Timeout time.Duration
	Logger  *slog.Logger
}

// RegisterPlacemarkEnricher wires the create + update hooks on the
// localities collection. The handler runs in a goroutine with a
// recover guard so an Ortus outage never blocks the originating
// save.
func RegisterPlacemarkEnricher(app core.App, e *PlacemarkEnricher) {
	e.App = app

	app.OnRecordCreateRequest("localities").BindFunc(func(ev *core.RecordRequestEvent) error {
		if err := ev.Next(); err != nil {
			return err
		}
		id := ev.Record.Id
		go e.runSafely(id)
		return nil
	})

	app.OnRecordUpdateRequest("localities").BindFunc(func(ev *core.RecordRequestEvent) error {
		// The pre-update state, captured before the save.
		original := ev.Record.Original()
		if err := ev.Next(); err != nil {
			return err
		}
		prevLat := original.GetFloat("latitude")
		prevLon := original.GetFloat("longitude")
		newLat := ev.Record.GetFloat("latitude")
		newLon := ev.Record.GetFloat("longitude")
		// Re-fire if the coordinate moved meaningfully OR if we
		// still have no placemark attached. The second clause
		// catches the case where an Ortus outage left a freshly
		// created locality without a result.
		if !fusion.SignificantCoordChange(prevLat, prevLon, newLat, newLon) &&
			ev.Record.GetString("placemark") != "" {
			return nil
		}
		id := ev.Record.Id
		go e.runSafely(id)
		return nil
	})
}

func (e *PlacemarkEnricher) log() *slog.Logger {
	if e.Logger != nil {
		return e.Logger
	}
	return e.App.Logger()
}

func (e *PlacemarkEnricher) timeout() time.Duration {
	if e.Timeout > 0 {
		return e.Timeout
	}
	return 15 * time.Second
}

func (e *PlacemarkEnricher) runSafely(localityID string) {
	defer func() {
		if r := recover(); r != nil {
			e.log().Error(
				"placemark panic",
				slog.String("locality_id", localityID),
				slog.Any("recover", r),
				slog.String("stack", string(debug.Stack())),
			)
		}
	}()
	if err := e.run(localityID); err != nil {
		e.log().Warn(
			"placemark enrich failed",
			slog.String("locality_id", localityID),
			slog.Any("err", err),
		)
	}
}

// EnrichLocality reverse-geocodes one locality synchronously (used by
// the backfill command), bounded by the enricher timeout. Manual
// placemarks stay untouched; without an Ortus client or coordinate it
// does nothing. An Ortus error is returned and leaves the locality
// unchanged.
func (e *PlacemarkEnricher) EnrichLocality(ctx context.Context, localityID string) error {
	ctx, cancel := context.WithTimeout(ctx, e.timeout())
	defer cancel()
	return e.enrich(ctx, localityID)
}

// run is the hook-side entry; tests in the same package drive it
// synchronously and assert on the post-state.
func (e *PlacemarkEnricher) run(localityID string) error {
	return e.EnrichLocality(context.Background(), localityID)
}

func (e *PlacemarkEnricher) enrich(ctx context.Context, localityID string) error {
	app := e.App
	loc, err := app.FindRecordById("localities", localityID)
	if err != nil {
		// Locality may have been merged away by the fusion hook
		// running in parallel — that's a benign race, not an
		// error.
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}

	// Manual overrides are sacrosanct (Spec §6.1): if the user
	// hand-edited the placemark, the auto-geocoder must not
	// stomp it.
	if pmID := loc.GetString("placemark"); pmID != "" {
		if pm, err := app.FindRecordById("placemarks", pmID); err == nil {
			if pm.GetString("geocoding_source") == "manual" {
				return nil
			}
		}
	}

	lat := loc.GetFloat("latitude")
	lon := loc.GetFloat("longitude")
	if lat == 0 && lon == 0 {
		// No coordinate yet — nothing to geocode.
		return nil
	}

	if e.Ortus == nil {
		// Test / dev mode without an Ortus client wired in.
		return nil
	}

	// Ortus outages are recoverable: the next coordinate update
	// re-fires the hook. No retry queue here.
	resp, err := e.Ortus.Query(ctx, lat, lon)
	if err != nil {
		return err
	}
	labels := e.Labels
	if labels == nil {
		labels = adminlabels.Default()
	}
	res := geoplace.FromOrtus(resp, lat, lon, labels)
	if res.Place == nil {
		// Open sea / no admin coverage: can't synthesize a placemark;
		// leave the locality alone.
		return nil
	}

	pmRec, err := geoplace.LookupOrCreatePlacemark(app, *res.Place, "backend_service", "")
	if err != nil {
		return err
	}

	if loc.GetString("placemark") == pmRec.Id {
		// Already attached to this exact placemark — nothing to
		// save. Spares an unnecessary version bump.
		return nil
	}
	loc.Set("placemark", pmRec.Id)
	return app.SaveNoValidate(loc)
}
