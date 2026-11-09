package geoplace

import (
	"testing"

	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"

	_ "go.mett.io/fwd-backend/migrations"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

func newStoreApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	return app
}

func mkUser(t *testing.T, app *tests.TestApp, email string) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatal(err)
	}
	u := models.NewRecord(coll)
	_ = u.SetEmail(email)
	_ = u.SetUsername(email[:5] + "x")
	_ = u.SetPassword("password1234")
	_ = u.SetVerified(true)
	if err := app.Dao().SaveRecord(u); err != nil {
		t.Fatalf("user: %v", err)
	}
	return u
}

func testPlace() Place {
	return Place{
		CountryISO: "ES",
		Admin: map[adminlabels.Tier]AdminValue{
			adminlabels.Tiers[0]: {Name: "Canarias", Native: "Canarias", Level: 4},
		},
		Island: "La Palma",
	}
}

func TestLookupOrCreate_ReusesSameHash(t *testing.T) {
	app := newStoreApp(t)
	a, err := LookupOrCreatePlacemark(app.Dao(), testPlace(), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := LookupOrCreatePlacemark(app.Dao(), testPlace(), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	if a.Id != b.Id {
		t.Errorf("ids differ: %s vs %s", a.Id, b.Id)
	}
	if a.GetString("country_iso") != "ES" || a.GetString("country") != "ES" {
		t.Errorf("country not set: %q/%q", a.GetString("country_iso"), a.GetString("country"))
	}
	if a.GetString("owner") != "" {
		t.Errorf("owner = %q", a.GetString("owner"))
	}
	got := PlaceFromRecord(a)
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
	a, err := LookupOrCreatePlacemark(app.Dao(), testPlace(), "manual", u1.Id)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LookupOrCreatePlacemark(app.Dao(), testPlace(), "manual", u2.Id)
	if err != nil {
		t.Fatal(err)
	}
	c, err := LookupOrCreatePlacemark(app.Dao(), testPlace(), "manual", u1.Id)
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
	coll, _ := app.Dao().FindCollectionByNameOrId("samples")
	rec := models.NewRecord(coll)
	v := 12.5
	ApplyGeo(rec, SampleGeo{ElevationDEM: &v, MTBSheetNumber: "6026", MTBQuadrant: 3, TerrainFlat: true})
	if rec.GetFloat("elevation_dem") != 12.5 || rec.GetInt("mtb_quadrant") != 3 || !rec.GetBool("terrain_flat") {
		t.Errorf("geo not applied: %v", rec.PublicExport())
	}
	ApplyGeo(rec, SampleGeo{})
	if rec.GetFloat("elevation_dem") != 0 || rec.GetInt("mtb_quadrant") != 0 || rec.GetString("mtb_sheet_number") != "" {
		t.Error("geo not cleared")
	}
}

func TestReplaceFeatures_ReplacesSet(t *testing.T) {
	app := newStoreApp(t)
	u := mkUser(t, app, "feat@example.com")
	sample := mkSample(t, app, u)
	fs := []Feature{
		{SourceID: "a", SourceName: "A", Layer: "l", FeatureID: "1", Properties: map[string]any{"k": "v"}},
		{SourceID: "b", SourceName: "B", Layer: "l", FeatureID: "2"},
	}
	if err := ReplaceFeatures(app.Dao(), sample.Id, u.Id, fs); err != nil {
		t.Fatal(err)
	}
	if err := ReplaceFeatures(app.Dao(), sample.Id, u.Id, fs[:1]); err != nil {
		t.Fatal(err)
	}
	recs, err := app.Dao().FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0, dbx.Params{"s": sample.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 1 || recs[0].GetString("source_id") != "a" || recs[0].GetString("owner") != u.Id {
		t.Fatalf("recs = %d", len(recs))
	}
	if recs[0].GetDateTime("fetched_at").IsZero() {
		t.Error("fetched_at unset")
	}
	if err := ReplaceFeatures(app.Dao(), sample.Id, u.Id, nil); err != nil {
		t.Fatal(err)
	}
	recs, _ = app.Dao().FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0, dbx.Params{"s": sample.Id})
	if len(recs) != 0 {
		t.Errorf("want empty, got %d", len(recs))
	}
}

func mkSample(t *testing.T, app *tests.TestApp, u *models.Record) *models.Record {
	t.Helper()
	ftc, _ := app.Dao().FindCollectionByNameOrId("fieldtrips")
	ft := models.NewRecord(ftc)
	ft.Set("owner", u.Id)
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("title", "T")
	ft.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	ft.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := app.Dao().SaveRecord(ft); err != nil {
		t.Fatalf("fieldtrip: %v", err)
	}
	sc, _ := app.Dao().FindCollectionByNameOrId("samples")
	s := models.NewRecord(sc)
	s.Set("owner", u.Id)
	s.Set("sample_id", "260519/1")
	s.Set("latitude", 49.793)
	s.Set("longitude", 9.939)
	s.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	s.Set("fieldtrip", ft.Id)
	if err := app.Dao().SaveRecord(s); err != nil {
		t.Fatalf("sample: %v", err)
	}
	return s
}
