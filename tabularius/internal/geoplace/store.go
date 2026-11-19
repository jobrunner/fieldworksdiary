package geoplace

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"go.mett.io/tabularius/internal/adminlabels"
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

// FeatureScope groups the rows of sample_features by the service that
// owns them. Each service replaces only its own rows.
type FeatureScope string

// Feature scopes.
const (
	ScopeOrtus  FeatureScope = "ortus"
	ScopeTempus FeatureScope = "tempus"
)

// TempusSourcePrefix starts the source_id of every Tempus feature.
const TempusSourcePrefix = "tempus:"

// ScopeOf returns the scope a source_id belongs to: Tempus for the
// "tempus:" prefix, Ortus for everything else (Ortus source ids are
// free-form).
func ScopeOf(sourceID string) FeatureScope {
	if strings.HasPrefix(sourceID, TempusSourcePrefix) {
		return ScopeTempus
	}
	return ScopeOrtus
}

// ErrForeignScope is returned when a feature does not belong to the
// scope that is being replaced.
var ErrForeignScope = errors.New("feature belongs to another scope")

func scopedFeatures(app core.App, sampleID string, scope FeatureScope) ([]*core.Record, error) {
	all, err := app.FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0,
		dbx.Params{"s": sampleID})
	if err != nil {
		return nil, err
	}
	out := all[:0]
	for _, r := range all {
		if ScopeOf(r.GetString("source_id")) == scope {
			out = append(out, r)
		}
	}
	return out, nil
}

// ReplaceFeatures replaces the features of one scope of a sample in one
// transaction; rows of the other scope stay. A feature of another scope
// in fs is rejected with ErrForeignScope and nothing is changed.
func ReplaceFeatures(app core.App, sampleID, ownerID string, scope FeatureScope, fs []Feature) error {
	for _, f := range fs {
		if ScopeOf(f.SourceID) != scope {
			return fmt.Errorf("%w: %q in %s", ErrForeignScope, f.SourceID, scope)
		}
	}
	return app.RunInTransaction(func(tx core.App) error {
		old, err := scopedFeatures(tx, sampleID, scope)
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

// featureKey renders a feature in a form comparable between the stored
// record and a freshly mapped one (fetched_at is ignored; empty and
// missing properties or license compare equal).
func featureKey(source, layer, id string, props, license any) string {
	norm := func(v any) string {
		raw, err := json.Marshal(v)
		if err != nil {
			return ""
		}
		var x any
		if json.Unmarshal(raw, &x) != nil {
			return string(raw)
		}
		out, _ := json.Marshal(x)
		// PocketBase stores a missing JSON object as {} and reads a
		// missing value back as null: both mean "nothing".
		if s := string(out); s != "null" && s != "{}" {
			return s
		}
		return ""
	}
	return strings.Join([]string{source, layer, id, norm(props), norm(license)}, "|")
}

// FeaturesChanged reports whether the stored features of one scope of
// the sample differ from fs.
func FeaturesChanged(app core.App, sampleID string, scope FeatureScope, fs []Feature) bool {
	old, err := scopedFeatures(app, sampleID, scope)
	if err != nil || len(old) != len(fs) {
		return true
	}
	have := map[string]int{}
	for _, r := range old {
		have[featureKey(r.GetString("source_id"), r.GetString("layer"), r.GetString("feature_id"),
			r.Get("properties"), r.Get("license"))]++
	}
	for _, f := range fs {
		var lic any
		if len(f.License) > 0 {
			lic = f.License
		}
		k := featureKey(f.SourceID, f.Layer, f.FeatureID, f.Properties, lic)
		if have[k] == 0 {
			return true
		}
		have[k]--
	}
	return false
}
