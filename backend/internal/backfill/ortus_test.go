package backfill

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/enrichment"
	"go.mett.io/fwd-backend/internal/geoplace"
	"go.mett.io/fwd-backend/internal/services"
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

const (
	testdata = "../../../shared/testdata/ortus/"
	deLat    = 49.681616
	deLon    = 10.039652
)

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

func newRunner(t *testing.T, app *tests.TestApp, labels *adminlabels.Table) (*Runner, *int) {
	return newRunnerFixture(t, app, labels, "query_de_ochsenfurt.json")
}

func newRunnerFixture(t *testing.T, app *tests.TestApp, labels *adminlabels.Table, fixture string) (*Runner, *int) {
	t.Helper()
	hits := new(int)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		raw, err := os.ReadFile(filepath.Join(testdata, fixture))
		if err != nil {
			w.WriteHeader(500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	}))
	t.Cleanup(srv.Close)
	ortus := &services.Ortus{BaseURL: srv.URL, HTTPClient: &http.Client{Timeout: 2 * time.Second}, MaxRetries: 1}
	return &Runner{
		App:      app,
		Enricher: &enrichment.Enricher{App: app, Ortus: ortus, Labels: labels, Timeout: 5 * time.Second},
		Labels:   labels,
		Interval: time.Millisecond,
	}, hits
}

func newUser(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	return newUserNamed(t, app, "bfuser")
}

func newUserNamed(t *testing.T, app *tests.TestApp, name string) *models.Record {
	t.Helper()
	coll, _ := app.Dao().FindCollectionByNameOrId("users")
	u := models.NewRecord(coll)
	_ = u.SetEmail(name + "@example.com")
	_ = u.SetUsername(name)
	_ = u.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(u); err != nil {
		t.Fatal(err)
	}
	return u
}

func newSample(t *testing.T, app *tests.TestApp, owner string, lat, lon float64, status string) *models.Record {
	t.Helper()
	return newSampleWithID(t, app, owner, lat, lon, status, "260519/"+status)
}

func newSampleWithID(t *testing.T, app *tests.TestApp, owner string, lat, lon float64, status, sid string) *models.Record {
	t.Helper()
	d := app.Dao()
	ftColl, _ := d.FindCollectionByNameOrId("fieldtrips")
	ft := models.NewRecord(ftColl)
	ft.Set("owner", owner)
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	ft.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := d.SaveRecord(ft); err != nil {
		t.Fatal(err)
	}
	coll, _ := d.FindCollectionByNameOrId("samples")
	s := models.NewRecord(coll)
	s.Set("owner", owner)
	s.Set("fieldtrip", ft.Id)
	s.Set("sample_id", sid)
	s.Set("latitude", lat)
	s.Set("longitude", lon)
	s.Set("begin_date", time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC))
	s.Set("location_status", status)
	if err := d.SaveRecord(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func newLocality(t *testing.T, app *tests.TestApp, owner, placemark string) *models.Record {
	t.Helper()
	coll, _ := app.Dao().FindCollectionByNameOrId("localities")
	l := models.NewRecord(coll)
	l.Set("owner", owner)
	l.Set("name", "Test")
	l.Set("latitude", deLat)
	l.Set("longitude", deLon)
	l.Set("location_source", "user")
	l.Set("version", 1)
	l.Set("placemark", placemark)
	if err := app.Dao().SaveRecord(l); err != nil {
		t.Fatal(err)
	}
	return l
}

func reload(t *testing.T, app *tests.TestApp, coll, id string) *models.Record {
	t.Helper()
	r, err := app.Dao().FindRecordById(coll, id)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// legacyManualPlacemark creates a pre-Ortus manual placemark (only legacy columns).
func legacyManualPlacemark(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	coll, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	pm := models.NewRecord(coll)
	pm.Set("country", "DE")
	pm.Set("administrative_area", "Bayern")
	pm.Set("sub_administrative_area", "Unterfranken")
	pm.Set("locality", "Würzburg")
	pm.Set("sub_locality", "Heidingsfeld")
	pm.Set("geocoding_source", "manual")
	pm.Set("dedup_hash", "legacyhash")
	if err := app.Dao().SaveRecord(pm); err != nil {
		t.Fatal(err)
	}
	return pm
}

func TestBackfill_LegacyManualMapped(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	pm := legacyManualPlacemark(t, app)
	newLocality(t, app, u.Id, pm.Id)
	r, _ := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, "placemarks", pm.Id)
	for col, want := range map[string]string{
		"country_iso": "DE", "admin_state": "Bayern", "admin_county": "Unterfranken",
		"admin_municipality": "Würzburg", "admin_submunicipality": "Heidingsfeld",
		"owner": u.Id, "geocoding_source": "manual",
	} {
		if got.GetString(col) != want {
			t.Errorf("%s = %q, want %q", col, got.GetString(col), want)
		}
	}
	if h := geoplace.PlaceFromRecord(got).DedupHash(); got.GetString("dedup_hash") != h {
		t.Errorf("dedup_hash not recomputed")
	}
}

func TestBackfill_SamplesEnriched(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, deLat, deLon, "pending")
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, "samples", s.Id)
	if got.GetString("location_status") != "backend_service" || got.GetString("placemark") == "" {
		t.Errorf("sample not enriched: status=%q", got.GetString("location_status"))
	}
	if got.GetString("mtb_sheet_number") != "6326" {
		t.Errorf("mtb = %q", got.GetString("mtb_sheet_number"))
	}
	if *hits != 1 {
		t.Errorf("hits = %d", *hits)
	}
}

func TestBackfill_Idempotent(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, deLat, deLon, "pending")
	pm := legacyManualPlacemark(t, app)
	newLocality(t, app, u.Id, pm.Id)
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	s1 := reload(t, app, "samples", s.Id)
	p1 := reload(t, app, "placemarks", pm.Id)
	h1 := *hits
	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	s2 := reload(t, app, "samples", s.Id)
	p2 := reload(t, app, "placemarks", pm.Id)
	if s1.GetInt("version") != s2.GetInt("version") || s1.GetString("placemark") != s2.GetString("placemark") ||
		s1.Updated.String() != s2.Updated.String() || p1.Updated.String() != p2.Updated.String() {
		t.Error("second run changed records")
	}
	if *hits != h1 {
		t.Errorf("second run hit ortus %d more times", *hits-h1)
	}
}

func TestBackfill_ManualSampleUntouched(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, deLat, deLon, "manual")
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, "samples", s.Id)
	if got.GetString("placemark_suggestion") != "" || got.GetInt("version") != s.GetInt("version") ||
		got.GetString("mtb_sheet_number") != "" {
		t.Error("manual sample was modified")
	}
	if *hits != 0 {
		t.Errorf("ortus hits = %d, want 0", *hits)
	}
}

func TestRemap_ColumnChangeMovesSamples(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, deLat, deLon, "pending")
	r, _ := newRunner(t, app, adminlabels.Default())
	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := reload(t, app, "samples", s.Id)
	oldPM := reload(t, app, "placemarks", before.GetString("placemark"))
	loc := newLocality(t, app, u.Id, oldPM.Id)

	// New table: DE level 8 (Ochsenfurt municipality) moves to admin_parish.
	labels := adminlabels.Default()
	c := labels.Countries["DE"]
	parish := adminlabels.Tier("admin_parish")
	levels := map[int]adminlabels.LevelEntry{}
	for k, v := range c.Levels {
		levels[k] = v
	}
	if e, ok := levels[8]; ok {
		e.Column = &parish
		levels[8] = e
	} else {
		t.Fatal("DE level 8 missing")
	}
	c.Levels = levels
	labels.Countries["DE"] = c
	r.Labels = labels

	if err := r.Remap(context.Background()); err != nil {
		t.Fatal(err)
	}
	after := reload(t, app, "samples", s.Id)
	newPM := reload(t, app, "placemarks", after.GetString("placemark"))
	if newPM.Id == oldPM.Id {
		t.Fatal("sample not moved")
	}
	if newPM.GetString("admin_parish") != oldPM.GetString("admin_municipality") || newPM.GetString("admin_municipality") != "" {
		t.Errorf("parish=%q municipality=%q", newPM.GetString("admin_parish"), newPM.GetString("admin_municipality"))
	}
	if reload(t, app, "localities", loc.Id).GetString("placemark") != newPM.Id {
		t.Error("locality not moved")
	}
	if after.GetInt("version") != before.GetInt("version")+1 {
		t.Error("version not bumped")
	}
	// second remap: no change
	if err := r.Remap(context.Background()); err != nil {
		t.Fatal(err)
	}
	if reload(t, app, "samples", s.Id).GetString("placemark") != newPM.Id {
		t.Error("remap not stable")
	}
}

func TestBackfill_Idempotent_SeaSample(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, 40.0, -30.0, "pending")
	r, _ := newRunnerFixture(t, app, adminlabels.Default(), "query_sea.json")

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	v1 := reload(t, app, "samples", s.Id).GetInt("version")
	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if v2 := reload(t, app, "samples", s.Id).GetInt("version"); v2 != v1 {
		t.Errorf("second run bumped version %d -> %d", v1, v2)
	}
}

func TestBackfill_LegacyManualSharedByTwoOwners(t *testing.T) {
	app := newApp(t)
	a := newUserNamed(t, app, "owner_a")
	b := newUserNamed(t, app, "owner_b")
	pm := legacyManualPlacemark(t, app)
	locA := newLocality(t, app, a.Id, pm.Id)
	locB := newLocality(t, app, b.Id, pm.Id)
	r, _ := newRunner(t, app, adminlabels.Default())

	if err := r.MapLegacyManual(context.Background()); err != nil {
		t.Fatal(err)
	}
	pa := reload(t, app, "localities", locA.Id).GetString("placemark")
	pb := reload(t, app, "localities", locB.Id).GetString("placemark")
	if pa == pb {
		t.Fatal("both owners still share one placemark")
	}
	for id, owner := range map[string]string{pa: a.Id, pb: b.Id} {
		p := reload(t, app, "placemarks", id)
		if p.GetString("owner") != owner || p.GetString("geocoding_source") != "manual" ||
			p.GetString("admin_municipality") != "Würzburg" {
			t.Errorf("placemark %s: owner=%q", id, p.GetString("owner"))
		}
	}
}

func TestRemap_OrphanNotCounted(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := newSample(t, app, u.Id, deLat, deLon, "pending")
	r, _ := newRunner(t, app, adminlabels.Default())
	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	labels := adminlabels.Default()
	c := labels.Countries["DE"]
	parish := adminlabels.Tier("admin_parish")
	levels := map[int]adminlabels.LevelEntry{}
	for k, v := range c.Levels {
		levels[k] = v
	}
	e := levels[8]
	e.Column = &parish
	levels[8] = e
	c.Levels = levels
	labels.Countries["DE"] = c
	r.Labels = labels
	if err := r.Remap(context.Background()); err != nil {
		t.Fatal(err)
	}
	v := reload(t, app, "samples", s.Id).GetInt("version")
	if err := r.Remap(context.Background()); err != nil {
		t.Fatal(err)
	}
	if reload(t, app, "samples", s.Id).GetInt("version") != v {
		t.Error("second remap changed the sample")
	}
}
