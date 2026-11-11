// Package backfill migrates existing data to the Ortus-based place model
// after deploy: samples without a backend place are enriched through
// Ortus (step B), samples still on the device timezone get the Ortus
// timezone (step B2), localities whose placemark predates Ortus are
// reverse-geocoded again (step B'), and backend placemarks are re-mapped
// after an admin-label table change (step C, Spec §4.3). Every step is
// idempotent. The former step A (legacy manual placemark texts → flat
// columns) runs inside migration 1700000027, before the legacy columns
// are dropped (geoplace.MapLegacyManualPlacemarks).
package backfill

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/enrichment"
	"go.mett.io/fwd-backend/internal/geoplace"

	"github.com/pocketbase/pocketbase/core"
)

// Runner executes the backfill steps.
type Runner struct {
	App core.App
	// Enricher performs the per-sample Ortus work (step B). Its Ortus
	// client may be nil; step B then does nothing.
	Enricher *enrichment.Enricher
	// Localities performs the per-locality Ortus work (step B'). Nil or
	// a nil Ortus client skips the step.
	Localities *enrichment.PlacemarkEnricher
	// Labels is the admin-label table used by the remap; nil means
	// adminlabels.Default().
	Labels *adminlabels.Table
	// Interval is the pause between Ortus calls; zero means 200 ms (5/s).
	Interval time.Duration
	Logger   *slog.Logger
}

func (r *Runner) log() *slog.Logger {
	if r.Logger != nil {
		return r.Logger
	}
	return slog.Default()
}

func (r *Runner) labels() *adminlabels.Table {
	if r.Labels != nil {
		return r.Labels
	}
	return adminlabels.Default()
}

// Run executes steps B, B2, B' and C in order.
func (r *Runner) Run(ctx context.Context) error {
	if err := r.EnrichSamples(ctx); err != nil {
		return fmt.Errorf("step B: %w", err)
	}
	if err := r.EnrichTimezones(ctx); err != nil {
		return fmt.Errorf("step B2: %w", err)
	}
	if err := r.EnrichLocalities(ctx); err != nil {
		return fmt.Errorf("step B': %w", err)
	}
	if err := r.Remap(ctx); err != nil {
		return fmt.Errorf("step C: %w", err)
	}
	return nil
}

func (r *Runner) interval() time.Duration {
	if r.Interval == 0 {
		return 200 * time.Millisecond
	}
	return r.Interval
}

// EnrichSamples (step B) enriches every sample with a coordinate whose
// location_status is neither manual nor backend_service, one at a time,
// rate limited. Samples that Ortus has no place for stay pending.
func (r *Runner) EnrichSamples(ctx context.Context) error {
	if r.Enricher == nil || r.Enricher.Ortus == nil {
		r.log().Warn("backfill: step B skipped, no ortus client", slog.String("service", "ortus"))
		return nil
	}
	recs, err := r.App.FindRecordsByFilter("samples",
		"(latitude != 0 || longitude != 0) && location_status != 'manual' && location_status != 'backend_service'",
		"created", 0, 0)
	if err != nil {
		return err
	}
	total := len(recs)
	r.log().Info("backfill: step B start", slog.Int("count", total))
	tick := time.NewTicker(r.interval())
	defer tick.Stop()
	for i, rec := range recs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if i > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-tick.C:
			}
		}
		r.Enricher.EnrichSample(ctx, rec.Id)
		if (i+1)%100 == 0 {
			r.log().Info("backfill: step B progress", slog.Int("done", i+1), slog.Int("count", total))
		}
	}
	r.log().Info("backfill: step B done", slog.Int("count", total))
	return nil
}

// EnrichTimezones (step B2) gives every sample with a coordinate whose
// timezone_source is still "device" the Ortus timezone, whatever its
// location_status (step B skips backend_service and manual samples, so
// rows enriched before Phase Z never got one). Only timezone and
// timezone_source change; a manual timezone is never selected. Rate
// limited like step B. Samples Ortus has no timezone for stay on device.
func (r *Runner) EnrichTimezones(ctx context.Context) error {
	if r.Enricher == nil || r.Enricher.Ortus == nil {
		r.log().Warn("backfill: step B2 skipped, no ortus client", slog.String("service", "ortus"))
		return nil
	}
	recs, err := r.App.FindRecordsByFilter("samples",
		"(latitude != 0 || longitude != 0) && timezone_source = 'device'", "created", 0, 0)
	if err != nil {
		return err
	}
	total, changed := len(recs), 0
	r.log().Info("backfill: step B2 start", slog.Int("count", total))
	tick := time.NewTicker(r.interval())
	defer tick.Stop()
	for i, rec := range recs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if i > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-tick.C:
			}
		}
		saved, err := r.Enricher.EnrichSampleTimezone(ctx, rec.Id)
		if err != nil {
			r.log().Warn("backfill: sample timezone failed",
				slog.String("sample_id", rec.Id), slog.String("service", "ortus"), slog.Any("err", err))
			continue
		}
		if saved {
			changed++
		}
	}
	r.log().Info("backfill: step B2 done", slog.Int("count", total), slog.Int("changed", changed))
	return nil
}

// EnrichLocalities (step B') reverse-geocodes every locality with a
// coordinate whose placemark is missing or a pre-Ortus backend row
// (backend_service without country_iso, e.g. from migration 20), one at
// a time, rate limited like step B. Manual placemarks are never touched;
// a locality Ortus has no place for keeps its placemark.
func (r *Runner) EnrichLocalities(ctx context.Context) error {
	if r.Localities == nil || r.Localities.Ortus == nil {
		r.log().Warn("backfill: step B' skipped, no ortus client", slog.String("service", "ortus"))
		return nil
	}
	dao := r.App
	locs, err := dao.FindRecordsByFilter("localities", "latitude != 0 || longitude != 0", "created", 0, 0)
	if err != nil {
		return err
	}
	var todo []string
	for _, loc := range locs {
		pmID := loc.GetString("placemark")
		if pmID == "" {
			todo = append(todo, loc.Id)
			continue
		}
		pm, err := dao.FindRecordById("placemarks", pmID)
		if err != nil {
			todo = append(todo, loc.Id) // dangling reference
			continue
		}
		if pm.GetString("geocoding_source") == "backend_service" && pm.GetString("country_iso") == "" {
			todo = append(todo, loc.Id)
		}
	}
	total := len(todo)
	r.log().Info("backfill: step B' start", slog.Int("count", total))
	tick := time.NewTicker(r.interval())
	defer tick.Stop()
	for i, id := range todo {
		if err := ctx.Err(); err != nil {
			return err
		}
		if i > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-tick.C:
			}
		}
		if err := r.Localities.EnrichLocality(ctx, id); err != nil {
			r.log().Warn("backfill: locality enrichment failed",
				slog.String("locality_id", id), slog.String("service", "ortus"), slog.Any("err", err))
		}
		if (i+1)%100 == 0 {
			r.log().Info("backfill: step B' progress", slog.Int("done", i+1), slog.Int("count", total))
		}
	}
	r.log().Info("backfill: step B' done", slog.Int("count", total))
	return nil
}

// Remap (step C) re-assigns every backend_service placemark with the
// current label table, using only its stored admin_<tier>_level values
// (no Ortus call). A changed dedup hash moves the referencing samples
// and localities to the looked-up/created placemark. Manual placemarks
// are never touched.
func (r *Runner) Remap(ctx context.Context) error {
	dao := r.App
	pms, err := dao.FindRecordsByFilter("placemarks",
		"geocoding_source = 'backend_service' && country_iso != ''", "created", 0, 0)
	if err != nil {
		return err
	}
	labels := r.labels()
	moved := 0
	for _, pm := range pms {
		if err := ctx.Err(); err != nil {
			return err
		}
		old := geoplace.PlaceFromRecord(pm)
		np := remapPlace(old, labels)
		if np.DedupHash() == old.DedupHash() {
			continue
		}
		changed := 0
		err := dao.RunInTransaction(func(tx core.App) error {
			target, err := geoplace.LookupOrCreatePlacemark(tx, np, "backend_service", "")
			if err != nil {
				return err
			}
			if target.Id == pm.Id {
				return nil
			}
			for _, field := range []string{"placemark", "placemark_suggestion"} {
				n, err := geoplace.Repoint(tx, "samples", field, pm.Id, target.Id, "")
				if err != nil {
					return err
				}
				changed += n
			}
			n, err := geoplace.Repoint(tx, "localities", "placemark", pm.Id, target.Id, "")
			changed += n
			return err
		})
		if err != nil {
			r.log().Warn("backfill: remap failed",
				slog.String("placemark_id", pm.Id), slog.Any("err", err))
			continue
		}
		if changed == 0 {
			continue // already-remapped orphan
		}
		moved++
		r.log().Info("backfill: placemark remapped", slog.String("placemark_id", pm.Id))
	}
	r.log().Info("backfill: step C done", slog.Int("count", moved))
	return nil
}

// remapPlace re-assigns the stored admin units of p to columns according
// to the table, mirroring geoplace's mapPlace (levels unknown to the table
// keep their current column; among known units the lower level wins).
func remapPlace(p geoplace.Place, t *adminlabels.Table) geoplace.Place {
	out := p
	out.Admin = map[adminlabels.Tier]geoplace.AdminValue{}
	type unit struct {
		col   adminlabels.Tier
		known bool
		v     geoplace.AdminValue
	}
	var units []unit
	for _, tier := range adminlabels.Tiers {
		v, ok := p.Admin[tier]
		if !ok {
			continue
		}
		if v.Level == 0 {
			out.Admin[tier] = v
			continue
		}
		col, known := t.Column(p.CountryISO, v.Level)
		switch {
		case known && col == "":
			continue
		case !known:
			col = tier
		}
		units = append(units, unit{col, known, v})
	}
	for _, u := range units {
		if cur, taken := out.Admin[u.col]; taken && (!u.known || cur.Level <= u.v.Level) {
			continue
		}
		out.Admin[u.col] = u.v
	}
	return out
}
