package geoplace

import (
	"database/sql"
	"errors"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

// ApplyPlace writes the place columns onto a placemark record. Tiers
// missing from p.Admin are cleared.
func ApplyPlace(rec *core.Record, p Place) {
	rec.Set("country_iso", p.CountryISO)
	for _, t := range adminlabels.Tiers {
		v := p.Admin[t]
		s := string(t)
		rec.Set(s, v.Name)
		rec.Set(s+"_level", v.Level)
		rec.Set(s+"_native", v.Native)
	}
	rec.Set("island", p.Island)
	rec.Set("mountain_range", p.MountainRange)
	rec.Set("mountain", p.Mountain)
}

// PlaceFromRecord reads the place columns of a placemark record.
func PlaceFromRecord(rec *core.Record) Place {
	p := Place{
		CountryISO:    rec.GetString("country_iso"),
		Admin:         map[adminlabels.Tier]AdminValue{},
		Island:        rec.GetString("island"),
		MountainRange: rec.GetString("mountain_range"),
		Mountain:      rec.GetString("mountain"),
	}
	for _, t := range adminlabels.Tiers {
		s := string(t)
		v := AdminValue{Name: rec.GetString(s), Native: rec.GetString(s + "_native"), Level: rec.GetInt(s + "_level")}
		if v != (AdminValue{}) {
			p.Admin[t] = v
		}
	}
	return p
}

// LookupOrCreatePlacemark finds the placemark with p's dedup hash, the
// given source ("backend_service" | "manual") and owner (empty for
// backend_service), or creates it. Safe to call with a transaction app.
func LookupOrCreatePlacemark(app core.App, p Place, source, ownerID string) (*core.Record, error) {
	hash := p.DedupHash()
	// A bound empty param does not match NULL relations; the literal
	// `owner = ''` does (PocketBase expands it to include NULL).
	filter := "dedup_hash = {:h} && geocoding_source = {:s} && owner = ''"
	params := dbx.Params{"h": hash, "s": source}
	if ownerID != "" {
		filter = "dedup_hash = {:h} && geocoding_source = {:s} && owner = {:o}"
		params["o"] = ownerID
	}
	// Oldest first, so concurrent duplicates converge on one row.
	recs, err := app.FindRecordsByFilter("placemarks", filter, "created", 1, 0, params)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if len(recs) > 0 {
		return recs[0], nil
	}
	coll, err := app.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return nil, err
	}
	rec := core.NewRecord(coll)
	ApplyPlace(rec, p)
	rec.Set("geocoding_source", source)
	rec.Set("geocoding_date", time.Now())
	rec.Set("dedup_hash", hash)
	if ownerID != "" {
		rec.Set("owner", ownerID)
	}
	if err := app.SaveNoValidate(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// ApplyGeo writes every SampleGeo field onto a sample record; nil
// pointers and zero values clear the field. It does not touch elevation
// or elevation_source.
func ApplyGeo(rec *core.Record, g SampleGeo) {
	num := func(name string, v *float64) {
		if v == nil {
			rec.Set(name, 0)
			return
		}
		rec.Set(name, *v)
	}
	num("slope_deg", g.SlopeDeg)
	num("aspect_deg", g.AspectDeg)
	num("bearing_distance_km", g.BearingDistanceKm)
	rec.Set("aspect_compass", g.AspectCompass)
	rec.Set("terrain_flat", g.TerrainFlat)
	rec.Set("bearing_label", g.BearingLabel)
	rec.Set("bearing_reference", g.BearingReference)
	rec.Set("bearing_compass", g.BearingCompass)
	rec.Set("bearing_inside", g.BearingInside)
	rec.Set("mtb_sheet_number", g.MTBSheetNumber)
	rec.Set("mtb_sheet_name", g.MTBSheetName)
	rec.Set("mtb_quadrant", g.MTBQuadrant)
}

// ReplaceFeatures replaces the complete feature set of a sample in one
// transaction.
func ReplaceFeatures(app core.App, sampleID, ownerID string, fs []Feature) error {
	return app.RunInTransaction(func(tx core.App) error {
		old, err := tx.FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0,
			dbx.Params{"s": sampleID})
		if err != nil {
			return err
		}
		for _, r := range old {
			if err := tx.Delete(r); err != nil {
				return err
			}
		}
		coll, err := tx.FindCollectionByNameOrId("sample_features")
		if err != nil {
			return err
		}
		now := time.Now()
		for _, f := range fs {
			rec := core.NewRecord(coll)
			rec.Set("owner", ownerID)
			rec.Set("sample", sampleID)
			rec.Set("source_id", f.SourceID)
			rec.Set("source_name", f.SourceName)
			rec.Set("layer", f.Layer)
			rec.Set("feature_id", f.FeatureID)
			rec.Set("properties", f.Properties)
			if len(f.License) > 0 {
				rec.Set("license", types.JSONRaw(f.License))
			}
			rec.Set("fetched_at", now)
			if err := tx.SaveNoValidate(rec); err != nil {
				return err
			}
		}
		return nil
	})
}
