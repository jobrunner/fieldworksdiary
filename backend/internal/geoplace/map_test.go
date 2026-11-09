package geoplace

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/services"
)

const testdata = "../../../shared/testdata/ortus/"

func loadQuery(t *testing.T, name string) *services.OrtusResponse {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(testdata, name))
	if err != nil {
		t.Fatal(err)
	}
	var r services.OrtusResponse
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatal(err)
	}
	return &r
}

type expectedFile struct {
	CountryISO string `json:"country_iso"`
	Admin      map[string]struct {
		Name   string `json:"name"`
		Native string `json:"native"`
		Level  int    `json:"level"`
	} `json:"admin"`
	Island        string `json:"island"`
	MountainRange string `json:"mountain_range"`
	Mountain      string `json:"mountain"`
	Geo           struct {
		ElevationDEM         float64 `json:"elevation_dem"`
		ElevationDEMAccuracy float64 `json:"elevation_dem_accuracy"`
		SlopeDeg             float64 `json:"slope_deg"`
		AspectDeg            float64 `json:"aspect_deg"`
		AspectCompass        string  `json:"aspect_compass"`
		TerrainFlat          bool    `json:"terrain_flat"`
		BearingLabel         string  `json:"bearing_label"`
		BearingReference     string  `json:"bearing_reference"`
		BearingCompass       string  `json:"bearing_compass"`
		BearingDistanceKm    float64 `json:"bearing_distance_km"`
		BearingInside        bool    `json:"bearing_inside"`
		MTBSheetNumber       string  `json:"mtb_sheet_number"`
		MTBSheetName         string  `json:"mtb_sheet_name"`
		MTBQuadrant          int     `json:"mtb_quadrant"`
	} `json:"geo"`
	FeatureCount int    `json:"feature_count"`
	DedupHash    string `json:"dedup_hash"`
}

func loadExpected(t *testing.T, name string) expectedFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(testdata, name))
	if err != nil {
		t.Fatal(err)
	}
	var e expectedFile
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatal(err)
	}
	return e
}

func fval(t *testing.T, name string, p *float64, want float64) {
	t.Helper()
	if p == nil || *p != want {
		t.Errorf("%s = %v, want %v", name, p, want)
	}
}

func TestFromOrtus_DE(t *testing.T) {
	q := loadQuery(t, "query_de_ochsenfurt.json")
	exp := loadExpected(t, "expected_de_ochsenfurt.json")
	res := FromOrtus(q, q.WGS84.Lat, q.WGS84.Lon, adminlabels.Default())

	if res.Place == nil {
		t.Fatal("Place nil")
	}
	p := res.Place
	if p.CountryISO != exp.CountryISO {
		t.Errorf("country = %q", p.CountryISO)
	}
	if len(p.Admin) != len(exp.Admin) {
		t.Errorf("admin has %d entries, want %d: %v", len(p.Admin), len(exp.Admin), p.Admin)
	}
	for tier, want := range exp.Admin {
		got := p.Admin[adminlabels.Tier(tier)]
		if got.Name != want.Name || got.Native != want.Native || got.Level != want.Level {
			t.Errorf("%s = %+v, want %+v", tier, got, want)
		}
	}
	if p.Island != exp.Island || p.MountainRange != exp.MountainRange || p.Mountain != exp.Mountain {
		t.Errorf("island/range/mountain = %q/%q/%q", p.Island, p.MountainRange, p.Mountain)
	}
	g := res.Geo
	fval(t, "elevation", g.ElevationDEM, exp.Geo.ElevationDEM)
	fval(t, "elevation acc", g.ElevationDEMAccuracy, exp.Geo.ElevationDEMAccuracy)
	fval(t, "slope", g.SlopeDeg, exp.Geo.SlopeDeg)
	fval(t, "aspect", g.AspectDeg, exp.Geo.AspectDeg)
	fval(t, "bearing km", g.BearingDistanceKm, exp.Geo.BearingDistanceKm)
	if g.AspectCompass != exp.Geo.AspectCompass || g.TerrainFlat != exp.Geo.TerrainFlat ||
		g.BearingLabel != exp.Geo.BearingLabel || g.BearingReference != exp.Geo.BearingReference ||
		g.BearingCompass != exp.Geo.BearingCompass || g.BearingInside != exp.Geo.BearingInside {
		t.Errorf("geo mismatch: %+v", g)
	}
	if g.MTBSheetNumber != "6326" || g.MTBSheetName != "Ochsenfurt" ||
		g.MTBSheetNumber != exp.Geo.MTBSheetNumber || g.MTBSheetName != exp.Geo.MTBSheetName {
		t.Errorf("mtb = %q/%q", g.MTBSheetNumber, g.MTBSheetName)
	}
	if g.MTBQuadrant != exp.Geo.MTBQuadrant || g.MTBQuadrant < 1 || g.MTBQuadrant > 4 {
		t.Errorf("quadrant = %d, want %d", g.MTBQuadrant, exp.Geo.MTBQuadrant)
	}
	if len(res.Features) != exp.FeatureCount {
		t.Errorf("features = %d", len(res.Features))
	}
	if got := p.DedupHash(); got != exp.DedupHash {
		t.Errorf("hash = %s, want %s", got, exp.DedupHash)
	}
}

func TestFromOrtus_FeatureFields(t *testing.T) {
	q := loadQuery(t, "query_de_ochsenfurt.json")
	res := FromOrtus(q, q.WGS84.Lat, q.WGS84.Lon, adminlabels.Default())
	f0, f1 := res.Features[0], res.Features[1]
	if f0.FeatureID != "6326" || f0.SourceID != "tk25-blattschnitt-de" || f0.Layer != "sheets" ||
		f0.SourceName != "tk25-blattschnitt-de.gpkg" || f0.Properties["blattname"] != "Ochsenfurt" {
		t.Errorf("f0 = %+v", f0)
	}
	if f1.FeatureID != "DE6326371" {
		t.Errorf("f1 id = %q", f1.FeatureID)
	}
	if len(f0.License) == 0 || string(f0.License) == string(f1.License) {
		t.Errorf("license not per-source: %s / %s", f0.License, f1.License)
	}
}

func TestFromOrtus_ESIsland(t *testing.T) {
	q := loadQuery(t, "query_es_lapalma.json")
	res := FromOrtus(q, q.WGS84.Lat, q.WGS84.Lon, adminlabels.Default())
	if res.Place == nil {
		t.Fatal("Place nil")
	}
	if got := res.Place.Admin["admin_state"].Name; got != "Canarias" {
		t.Errorf("admin_state = %q", got)
	}
	if res.Place.Island != "La Palma" || res.Place.Mountain != "Pico Bejenado" {
		t.Errorf("island/mountain = %q/%q", res.Place.Island, res.Place.Mountain)
	}
	if res.Geo.MTBSheetNumber != "" || res.Geo.MTBSheetName != "" || res.Geo.MTBQuadrant != 0 {
		t.Errorf("mtb not empty: %+v", res.Geo)
	}
}

func TestFromOrtus_SeaNoPlace(t *testing.T) {
	q := loadQuery(t, "query_sea.json")
	res := FromOrtus(q, 40, -25, adminlabels.Default())
	if res.Place != nil {
		t.Errorf("Place = %+v, want nil", res.Place)
	}
	if res.Geo.ElevationDEM != nil {
		t.Errorf("elevation should be nil")
	}
}

func TestFromOrtus_SeaLevelElevationZero(t *testing.T) {
	r := &services.OrtusResponse{Gazetteer: &services.OrtusGazetteer{
		Elevation: &services.OrtusElevation{Meters: 3, SeaLevel: true, AccuracyM: 2},
	}}
	res := FromOrtus(r, 0, 0, adminlabels.Default())
	fval(t, "elevation", res.Geo.ElevationDEM, 0)
	if res.Place != nil {
		t.Error("Place should be nil")
	}
}

func TestFromOrtus_Nil(t *testing.T) {
	res := FromOrtus(&services.OrtusResponse{}, 0, 0, adminlabels.Default())
	if res.Place != nil || len(res.Features) != 0 {
		t.Errorf("unexpected %+v", res)
	}
}

func TestFromOrtus_UnknownCountryFallsBackToEquivalent(t *testing.T) {
	r := &services.OrtusResponse{Gazetteer: &services.OrtusGazetteer{Admin: &struct {
		CountryISO string                    `json:"country_iso"`
		Hierarchy  []services.OrtusAdminUnit `json:"hierarchy"`
	}{CountryISO: "ZZ", Hierarchy: []services.OrtusAdminUnit{
		{Level: 8, Name: "Foo", Equivalent: "municipality"},
		{Level: 7, Name: "Bar", Equivalent: "municipality"},
		{Level: 2, Name: "Zedland", Equivalent: "country"},
	}}}}
	res := FromOrtus(r, 0, 0, &adminlabels.Table{})
	if res.Place == nil {
		t.Fatal("nil place")
	}
	// fallback only fills a free column: the first unit keeps it
	if got := res.Place.Admin["admin_municipality"]; got.Name != "Foo" || got.Level != 8 {
		t.Errorf("municipality = %+v", got)
	}
	if res.Place.Admin["admin_country"].Name != "Zedland" {
		t.Errorf("country missing")
	}
}

func TestFromOrtus_KnownButNotStoredSkipped(t *testing.T) {
	// DE: find a level that is known but not stored, if any
	tbl := adminlabels.Default()
	level := -1
	for l := 1; l <= 12; l++ {
		if c, ok := tbl.Column("DE", l); ok && c == "" {
			level = l
			break
		}
	}
	if level < 0 {
		t.Skip("no known-but-unstored DE level")
	}
	r := &services.OrtusResponse{Gazetteer: &services.OrtusGazetteer{Admin: &struct {
		CountryISO string                    `json:"country_iso"`
		Hierarchy  []services.OrtusAdminUnit `json:"hierarchy"`
	}{CountryISO: "DE", Hierarchy: []services.OrtusAdminUnit{
		{Level: level, Name: "X", Equivalent: "other"},
	}}}}
	res := FromOrtus(r, 0, 0, tbl)
	if len(res.Place.Admin) != 0 {
		t.Errorf("admin = %v", res.Place.Admin)
	}
}

func TestDedupHash_StableAndCaseInsensitive(t *testing.T) {
	a := Place{CountryISO: "DE", Admin: map[adminlabels.Tier]AdminValue{"admin_municipality": {Name: " Würzburg "}}}
	b := Place{CountryISO: "de", Admin: map[adminlabels.Tier]AdminValue{"admin_municipality": {Name: "WÜRZBURG"}}}
	// decomposed ü (u + combining diaeresis)
	c := Place{CountryISO: "DE", Admin: map[adminlabels.Tier]AdminValue{"admin_municipality": {Name: "Würzburg"}}}
	if a.DedupHash() != b.DedupHash() || a.DedupHash() != c.DedupHash() {
		t.Error("hash should ignore case, whitespace and normalization form")
	}
	if a.DedupHash() != a.DedupHash() || len(a.DedupHash()) != 64 {
		t.Error("hash unstable or wrong length")
	}
	d := Place{CountryISO: "DE", Admin: map[adminlabels.Tier]AdminValue{"admin_county": {Name: "Würzburg"}}}
	if a.DedupHash() == d.DedupHash() {
		t.Error("different tiers must hash differently")
	}
	e := Place{CountryISO: "DE", Island: "x"}
	f := Place{CountryISO: "DE", Mountain: "x"}
	if e.DedupHash() == f.DedupHash() {
		t.Error("island vs mountain must differ")
	}
}

func TestDedupHash_NativeAndLevelMatter(t *testing.T) {
	tier := adminlabels.Tiers[1]
	mk := func(native string, level int) Place {
		return Place{CountryISO: "ES", Admin: map[adminlabels.Tier]AdminValue{tier: {Name: "Canarias", Native: native, Level: level}}}
	}
	base := mk("Canarias", 4).DedupHash()
	if base == mk("Fake", 4).DedupHash() || base == mk("Canarias", 5).DedupHash() {
		t.Error("native/level must change the hash")
	}
}
