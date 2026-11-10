// Package backfill migrates existing data to the Ortus-based place model:
// legacy manual placemarks get the new flat columns (step A), samples
// without a backend place are enriched through Ortus (step B), and
// backend placemarks are re-mapped after an admin-label table change
// (step C, Spec §4.3). Every step is idempotent.
package backfill

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/enrichment"
	"go.mett.io/fwd-backend/internal/geoplace"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
)

// Runner executes the backfill steps.
type Runner struct {
	App core.App
	// Enricher performs the per-sample Ortus work (step B). Its Ortus
	// client may be nil; step B then does nothing.
	Enricher *enrichment.Enricher
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

// Run executes steps A, B and C in order.
func (r *Runner) Run(ctx context.Context) error {
	if err := r.MapLegacyManual(ctx); err != nil {
		return fmt.Errorf("step A: %w", err)
	}
	if err := r.EnrichSamples(ctx); err != nil {
		return fmt.Errorf("step B: %w", err)
	}
	if err := r.Remap(ctx); err != nil {
		return fmt.Errorf("step C: %w", err)
	}
	return nil
}

// MapLegacyManual (step A) moves the legacy text columns of manual
// placemarks onto the new flat columns and fills the owner from the
// referencing locality (or sample). Source stays manual.
func (r *Runner) MapLegacyManual(ctx context.Context) error {
	dao := r.App.Dao()
	pms, err := dao.FindRecordsByFilter("placemarks",
		"geocoding_source = 'manual' && country_iso = '' && country != ''", "created", 0, 0)
	if err != nil {
		return err
	}
	done := 0
	for _, pm := range pms {
		if err := ctx.Err(); err != nil {
			return err
		}
		old := map[string]string{
			"country":                 pm.GetString("country"),
			"administrative_area":     pm.GetString("administrative_area"),
			"sub_administrative_area": pm.GetString("sub_administrative_area"),
			"locality":                pm.GetString("locality"),
			"sub_locality":            pm.GetString("sub_locality"),
		}
		p := geoplace.Place{
			CountryISO: old["country"],
			Admin:      map[adminlabels.Tier]geoplace.AdminValue{},
		}
		for legacy, tier := range map[string]adminlabels.Tier{
			"administrative_area":     "admin_state",
			"sub_administrative_area": "admin_county",
			"locality":                "admin_municipality",
			"sub_locality":            "admin_submunicipality",
		} {
			if old[legacy] != "" {
				p.Admin[tier] = geoplace.AdminValue{Name: old[legacy]}
			}
		}
		owner := pm.GetString("owner")
		if owner == "" {
			owner = referencingOwner(dao, pm.Id)
		}
		geoplace.ApplyPlace(pm, p)
		pm.Set("dedup_hash", p.DedupHash())
		if owner != "" {
			pm.Set("owner", owner)
		}
		if err := dao.SaveRecord(pm); err != nil {
			return fmt.Errorf("save placemark %s: %w", pm.Id, err)
		}
		done++
		r.log().Info("backfill: legacy manual placemark",
			slog.String("placemark_id", pm.Id),
			slog.String("user_id", owner),
			slog.String("old_country", old["country"]),
			slog.String("old_administrative_area", old["administrative_area"]),
			slog.String("old_sub_administrative_area", old["sub_administrative_area"]),
			slog.String("old_locality", old["locality"]),
			slog.String("old_sub_locality", old["sub_locality"]),
			slog.String("new_country_iso", p.CountryISO),
			slog.String("new_admin_state", p.Admin["admin_state"].Name),
			slog.String("new_admin_county", p.Admin["admin_county"].Name),
			slog.String("new_admin_municipality", p.Admin["admin_municipality"].Name),
			slog.String("new_admin_submunicipality", p.Admin["admin_submunicipality"].Name),
		)
	}
	r.log().Info("backfill: step A done", slog.Int("count", done))
	return nil
}

func referencingOwner(dao *daos.Dao, placemarkID string) string {
	for _, coll := range []string{"localities", "samples"} {
		recs, err := dao.FindRecordsByFilter(coll, "placemark = {:p}", "created", 1, 0, dbx.Params{"p": placemarkID})
		if err == nil && len(recs) > 0 {
			if o := recs[0].GetString("owner"); o != "" {
				return o
			}
		}
	}
	return ""
}

// EnrichSamples (step B) enriches every sample with a coordinate whose
// location_status is neither manual nor backend_service, one at a time,
// rate limited. Samples that Ortus has no place for stay pending.
func (r *Runner) EnrichSamples(ctx context.Context) error {
	if r.Enricher == nil || r.Enricher.Ortus == nil {
		r.log().Warn("backfill: step B skipped, no ortus client", slog.String("service", "ortus"))
		return nil
	}
	interval := r.Interval
	if interval == 0 {
		interval = 200 * time.Millisecond
	}
	recs, err := r.App.Dao().FindRecordsByFilter("samples",
		"(latitude != 0 || longitude != 0) && location_status != 'manual' && location_status != 'backend_service'",
		"created", 0, 0)
	if err != nil {
		return err
	}
	total := len(recs)
	r.log().Info("backfill: step B start", slog.Int("count", total))
	tick := time.NewTicker(interval)
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

// Remap (step C) re-assigns every backend_service placemark with the
// current label table, using only its stored admin_<tier>_level values
// (no Ortus call). A changed dedup hash moves the referencing samples
// and localities to the looked-up/created placemark. Manual placemarks
// are never touched.
func (r *Runner) Remap(ctx context.Context) error {
	dao := r.App.Dao()
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
		err := dao.RunInTransaction(func(tx *daos.Dao) error {
			target, err := geoplace.LookupOrCreatePlacemark(tx, np, "backend_service", "")
			if err != nil {
				return err
			}
			if target.Id == pm.Id {
				return nil
			}
			for _, field := range []string{"placemark", "placemark_suggestion"} {
				if err := repoint(tx, "samples", field, pm.Id, target.Id); err != nil {
					return err
				}
			}
			return repoint(tx, "localities", "placemark", pm.Id, target.Id)
		})
		if err != nil {
			r.log().Warn("backfill: remap failed",
				slog.String("placemark_id", pm.Id), slog.Any("err", err))
			continue
		}
		moved++
		r.log().Info("backfill: placemark remapped", slog.String("placemark_id", pm.Id))
	}
	r.log().Info("backfill: step C done", slog.Int("count", moved))
	return nil
}

// repoint sets field=to on every record of coll whose field is from,
// bumping the version so clients holding the old one get a 409.
func repoint(tx *daos.Dao, coll, field, from, to string) error {
	recs, err := tx.FindRecordsByFilter(coll, field+" = {:f}", "", 0, 0, dbx.Params{"f": from})
	if err != nil {
		return err
	}
	for _, rec := range recs {
		rec.Set(field, to)
		rec.Set("version", rec.GetInt("version")+1)
		if err := tx.SaveRecord(rec); err != nil {
			return err
		}
	}
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
