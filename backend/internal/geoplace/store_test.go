package geoplace_test

import (
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/testutil"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	_ "go.mett.io/fwd-backend/migrations"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/geoplace"
)

func newStoreApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app := testutil.NewTestApp(t)
	return app
}

func mkUser(t *testing.T, app *tests.TestApp, email string) *core.Record {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatal(err)
	}
	u := core.NewRecord(coll)
	u.SetEmail(email)
	u.Set("username", email[:5]+"x")
	u.SetPassword("password1234")
	u.SetVerified(true)
	if err := app.SaveNoValidate(u); err != nil {
		t.Fatalf("user: %v", err)
	}
	return u
}

func testPlace() geoplace.Place {
	return geoplace.Place{
		CountryISO: "ES",
		Admin: map[adminlabels.Tier]geoplace.AdminValue{
			adminlabels.Tiers[0]: {Name: "Canarias", Native: "Canarias", Level: 4},
		},
		Island: "La Palma",
	}
}

func TestLookupOrCreate_ReusesSameHash(t *testing.T) {
	app := newStoreApp(t)
	a, err := geoplace.LookupOrCreatePlacemark(app, testPlace(), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := geoplace.LookupOrCreatePlacemark(app, testPlace(), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	if a.Id != b.Id {
		t.Errorf("ids differ: %s vs %s", a.Id, b.Id)
	}
	if a.GetString("country_iso") != "ES" {
		t.Errorf("country_iso = %q", a.GetString("country_iso"))
	}
	if a.GetString("owner") != "" {
		t.Errorf("owner = %q", a.GetString("owner"))
	}
	got := geoplace.PlaceFromRecord(a)
	if got.Island != "La Palma" || got.Admin[adminlabels.Tiers[0]].Level != 4 {
		t.Errorf("roundtrip: %+v", got)
	}
	if got.DedupHash() != testPlace().DedupHash() {
		t.Error("hash differs after roundtrip")
	}
}

func TestLookupOrCreate_ManualScopedPerOwner(t *testing.T) {
	app := newStoreApp(t)
	u1 := mkUser(t, app, "one@example.com")
	u2 := mkUser(t, app, "two@example.com")
	a, err := geoplace.LookupOrCreatePlacemark(app, testPlace(), "manual", u1.Id)
	if err != nil {
		t.Fatal(err)
	}
	b, err := geoplace.LookupOrCreatePlacemark(app, testPlace(), "manual", u2.Id)
	if err != nil {
		t.Fatal(err)
	}
	c, err := geoplace.LookupOrCreatePlacemark(app, testPlace(), "manual", u1.Id)
	if err != nil {
		t.Fatal(err)
	}
	if a.Id == b.Id {
		t.Error("two owners share a record")
	}
	if a.Id != c.Id {
		t.Error("same owner did not reuse")
	}
	if a.GetString("owner") != u1.Id {
		t.Errorf("owner = %q", a.GetString("owner"))
	}
}

func TestApplyGeo_ClearsNil(t *testing.T) {
	app := newStoreApp(t)
	coll, _ := app.FindCollectionByNameOrId("samples")
	rec := core.NewRecord(coll)
	v := 12.5
	geoplace.ApplyGeo(rec, geoplace.SampleGeo{ElevationDEM: &v, MTBSheetNumber: "6026", MTBQuadrant: 3, TerrainFlat: true})
	if rec.GetInt("mtb_quadrant") != 3 || !rec.GetBool("terrain_flat") {
		t.Errorf("geo not applied: %v", rec.PublicExport())
	}
	geoplace.ApplyGeo(rec, geoplace.SampleGeo{})
	if rec.GetInt("mtb_quadrant") != 0 || rec.GetString("mtb_sheet_number") != "" {
		t.Error("geo not cleared")
	}
}

func TestReplaceFeatures_ReplacesSet(t *testing.T) {
	app := newStoreApp(t)
	u := mkUser(t, app, "feat@example.com")
	sample := mkSample(t, app, u)
	fs := []geoplace.Feature{
		{SourceID: "a", SourceName: "A", Layer: "l", FeatureID: "1", Properties: map[string]any{"k": "v"}},
		{SourceID: "b", SourceName: "B", Layer: "l", FeatureID: "2"},
	}
	if err := geoplace.ReplaceFeatures(app, sample.Id, u.Id, fs); err != nil {
		t.Fatal(err)
	}
	if err := geoplace.ReplaceFeatures(app, sample.Id, u.Id, fs[:1]); err != nil {
		t.Fatal(err)
	}
	recs, err := app.FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0, dbx.Params{"s": sample.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 1 || recs[0].GetString("source_id") != "a" || recs[0].GetString("owner") != u.Id {
		t.Fatalf("recs = %d", len(recs))
	}
	if recs[0].GetDateTime("fetched_at").IsZero() {
		t.Error("fetched_at unset")
	}
	if err := geoplace.ReplaceFeatures(app, sample.Id, u.Id, nil); err != nil {
		t.Fatal(err)
	}
	recs, _ = app.FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0, dbx.Params{"s": sample.Id})
	if len(recs) != 0 {
		t.Errorf("want empty, got %d", len(recs))
	}
}

func mkSample(t *testing.T, app *tests.TestApp, u *core.Record) *core.Record {
	t.Helper()
	ftc, _ := app.FindCollectionByNameOrId("fieldtrips")
	ft := core.NewRecord(ftc)
	ft.Set("owner", u.Id)
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("title", "T")
	ft.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	ft.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatalf("fieldtrip: %v", err)
	}
	sc, _ := app.FindCollectionByNameOrId("samples")
	s := core.NewRecord(sc)
	s.Set("owner", u.Id)
	s.Set("sample_id", "260519/1")
	s.Set("latitude", 49.793)
	s.Set("longitude", 9.939)
	s.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	s.Set("fieldtrip", ft.Id)
	if err := app.SaveNoValidate(s); err != nil {
		t.Fatalf("sample: %v", err)
	}
	return s
}

// ApplyGeo must not write elevation_dem* (columns are gone): the sample
// collection saves without them.
func TestApplyGeo_NoDEMColumns(t *testing.T) {
	app := newStoreApp(t)
	u := mkUser(t, app, "nodem@example.com")
	sample := mkSample(t, app, u)
	v, acc := 12.5, 3.0
	geoplace.ApplyGeo(sample, geoplace.SampleGeo{ElevationDEM: &v, ElevationDEMAccuracy: &acc})
	if err := app.SaveNoValidate(sample); err != nil {
		t.Fatal(err)
	}
	for _, f := range sample.Collection().Fields {
		if f.GetName() == "elevation_dem" || f.GetName() == "elevation_dem_accuracy" {
			t.Errorf("column %s still in schema", f.GetName())
		}
	}
	if sample.Get("elevation_dem") != nil {
		t.Error("ApplyGeo set elevation_dem")
	}
}
