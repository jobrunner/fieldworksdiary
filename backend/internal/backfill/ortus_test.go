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
		Localities: &enrichment.PlacemarkEnricher{
			App: app, Ortus: ortus, Labels: labels, Timeout: 5 * time.Second,
		},
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
	loc := newLocality(t, app, u.Id, legacyBackendPlacemark(t, app).Id)
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	s1 := reload(t, app, "samples", s.Id)
	l1 := reload(t, app, "localities", loc.Id)
	h1 := *hits
	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	s2 := reload(t, app, "samples", s.Id)
	l2 := reload(t, app, "localities", loc.Id)
	if s1.GetInt("version") != s2.GetInt("version") || s1.GetString("placemark") != s2.GetString("placemark") ||
		s1.Updated.String() != s2.Updated.String() || l1.Updated.String() != l2.Updated.String() {
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

// legacyBackendPlacemark creates a pre-Ortus backend placemark as
// migration 20 left it: backend_service without country_iso.
func legacyBackendPlacemark(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	coll, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	pm := models.NewRecord(coll)
	pm.Set("geocoding_source", "backend_service")
	pm.Set("dedup_hash", "legacybackendhash")
	if err := app.Dao().SaveRecord(pm); err != nil {
		t.Fatal(err)
	}
	return pm
}

func TestBackfill_LocalityWithLegacyBackendPlacemarkReenriched(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	old := legacyBackendPlacemark(t, app)
	loc := newLocality(t, app, u.Id, old.Id)
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, "localities", loc.Id).GetString("placemark")
	if got == "" || got == old.Id {
		t.Fatalf("locality placemark = %q, want a new Ortus placemark", got)
	}
	pm := reload(t, app, "placemarks", got)
	if pm.GetString("country_iso") != "DE" || pm.GetString("geocoding_source") != "backend_service" ||
		pm.GetString("admin_municipality") == "" {
		t.Errorf("placemark: iso=%q source=%q municipality=%q", pm.GetString("country_iso"),
			pm.GetString("geocoding_source"), pm.GetString("admin_municipality"))
	}
	if *hits != 1 {
		t.Errorf("hits = %d, want 1", *hits)
	}
	if err := r.EnrichLocalities(context.Background()); err != nil {
		t.Fatal(err)
	}
	if *hits != 1 {
		t.Errorf("second run hit ortus again (hits = %d)", *hits)
	}
}

func TestBackfill_LocalityWithoutPlacemarkEnriched(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	loc := newLocality(t, app, u.Id, "")
	r, _ := newRunner(t, app, adminlabels.Default())

	if err := r.EnrichLocalities(context.Background()); err != nil {
		t.Fatal(err)
	}
	pmID := reload(t, app, "localities", loc.Id).GetString("placemark")
	if pmID == "" || reload(t, app, "placemarks", pmID).GetString("country_iso") != "DE" {
		t.Errorf("locality not enriched: placemark=%q", pmID)
	}
}

func TestBackfill_LocalityWithManualPlacemarkUntouched(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	coll, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	pm := models.NewRecord(coll)
	pm.Set("geocoding_source", "manual")
	pm.Set("owner", u.Id)
	pm.Set("admin_municipality", "Eigener Ort")
	pm.Set("dedup_hash", "manualhash")
	if err := app.Dao().SaveRecord(pm); err != nil {
		t.Fatal(err)
	}
	loc := newLocality(t, app, u.Id, pm.Id)
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.EnrichLocalities(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := reload(t, app, "localities", loc.Id).GetString("placemark"); got != pm.Id {
		t.Errorf("manual placemark replaced: %q", got)
	}
	if *hits != 0 {
		t.Errorf("hits = %d, want 0", *hits)
	}
}

func TestBackfill_LocalitiesSkippedWithoutOrtus(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	loc := newLocality(t, app, u.Id, "")
	r := &Runner{App: app}
	if err := r.EnrichLocalities(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := reload(t, app, "localities", loc.Id).GetString("placemark"); got != "" {
		t.Errorf("placemark = %q, want empty", got)
	}
}

// tzSample creates a sample with the given location status and timezone.
func tzSample(t *testing.T, app *tests.TestApp, owner, status, sid, tz, tzSource string) *models.Record {
	t.Helper()
	s := newSampleWithID(t, app, owner, deLat, deLon, status, sid)
	s.Set("timezone", tz)
	s.Set("timezone_source", tzSource)
	s.Set("placemark", "")
	s.Set("version", 3)
	if err := app.Dao().SaveRecord(s); err != nil {
		t.Fatal(err)
	}
	return reload(t, app, "samples", s.Id)
}

func TestBackfill_TimezoneForEnrichedAndManualSamples(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	backend := tzSample(t, app, u.Id, "backend_service", "260519/tz1", "UTC", "device")
	manualLoc := tzSample(t, app, u.Id, "manual", "260519/tz2", "UTC", "device")
	manualTZ := tzSample(t, app, u.Id, "backend_service", "260519/tz3", "Asia/Tokyo", "manual")
	r, hits := newRunner(t, app, adminlabels.Default())

	if err := r.EnrichTimezones(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, before := range []*models.Record{backend, manualLoc} {
		got := reload(t, app, "samples", before.Id)
		if got.GetString("timezone") != "Europe/Berlin" || got.GetString("timezone_source") != "location_service" {
			t.Errorf("%s: timezone=%q source=%q", before.GetString("sample_id"),
				got.GetString("timezone"), got.GetString("timezone_source"))
		}
		if got.GetInt("version") != before.GetInt("version")+1 {
			t.Errorf("%s: version %d -> %d, want +1", before.GetString("sample_id"),
				before.GetInt("version"), got.GetInt("version"))
		}
		if got.GetString("location_status") != before.GetString("location_status") ||
			got.GetString("placemark") != "" || got.GetString("placemark_suggestion") != "" ||
			got.GetString("mtb_sheet_number") != "" {
			t.Errorf("%s: more than the timezone changed", before.GetString("sample_id"))
		}
	}
	got := reload(t, app, "samples", manualTZ.Id)
	if got.GetString("timezone") != "Asia/Tokyo" || got.GetString("timezone_source") != "manual" ||
		got.GetInt("version") != manualTZ.GetInt("version") {
		t.Errorf("manual timezone touched: %q %q v%d", got.GetString("timezone"),
			got.GetString("timezone_source"), got.GetInt("version"))
	}
	if *hits != 2 {
		t.Errorf("hits = %d, want 2", *hits)
	}

	// Second run selects nothing.
	if err := r.EnrichTimezones(context.Background()); err != nil {
		t.Fatal(err)
	}
	if *hits != 2 {
		t.Errorf("second run hit ortus (hits = %d)", *hits)
	}
	if v := reload(t, app, "samples", backend.Id).GetInt("version"); v != backend.GetInt("version")+1 {
		t.Errorf("second run bumped version to %d", v)
	}
}

func TestBackfill_TimezonesSkippedWithoutOrtus(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	s := tzSample(t, app, u.Id, "backend_service", "260519/tz4", "UTC", "device")
	r := &Runner{App: app}
	if err := r.EnrichTimezones(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := reload(t, app, "samples", s.Id); got.GetString("timezone_source") != "device" {
		t.Errorf("timezone_source = %q", got.GetString("timezone_source"))
	}
}
