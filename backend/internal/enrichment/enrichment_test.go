package enrichment

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/geoplace"
	"go.mett.io/fwd-backend/internal/services"
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// ────────────────────────────────────────────────────────────────────
// Pure-Function-Tests — keine DB, kein Netz
// ────────────────────────────────────────────────────────────────────

func TestCentroid_EmptyReturnsZero(t *testing.T) {
	lat, lon := centroid(nil)
	if lat != 0 || lon != 0 {
		t.Errorf("centroid(nil) = (%v, %v), want (0, 0)", lat, lon)
	}
}

func TestCentroid_AveragesLatLon(t *testing.T) {
	app := newAppForRecordsOnly(t)
	coll, _ := app.Dao().FindCollectionByNameOrId("samples")

	mk := func(lat, lon float64) *models.Record {
		r := models.NewRecord(coll)
		r.Set("latitude", lat)
		r.Set("longitude", lon)
		return r
	}
	samples := []*models.Record{
		mk(49.0, 9.0),
		mk(51.0, 11.0),
	}
	lat, lon := centroid(samples)
	if lat != 50.0 || lon != 10.0 {
		t.Errorf("centroid = (%v, %v), want (50.0, 10.0)", lat, lon)
	}
}

func TestParseCollectingDay_AnchorsAtNoon(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	day := parseCollectingDay("2026-05-19", loc)
	if h := day.Hour(); h != 12 {
		t.Errorf("hour = %d, want 12 (Anker auf Mittag wegen DST)", h)
	}
	if day.Location().String() != "Europe/Berlin" {
		t.Errorf("location = %q, want Europe/Berlin", day.Location())
	}
}

func TestParseCollectingDay_InvalidFormatFallsBackToNow(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	day := parseCollectingDay("not-a-date", loc)
	if time.Since(day) > time.Second {
		t.Errorf("fallback day too old: %v", day)
	}
}

// ────────────────────────────────────────────────────────────────────
// Integration mit echtem PB-Test-App + httptest-Fake-Services
// ────────────────────────────────────────────────────────────────────

func newAppForRecordsOnly(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

// createOwnerSampleFieldtrip legt einen User + eine Fieldtrip + ein
// Sample mit (lat, lon) an. Owner-Beziehungen werden direkt gesetzt,
// damit wir keine Hook-Cascade brauchen.
func createOwnerSampleFieldtrip(t *testing.T, app *tests.TestApp, lat, lon float64) (ownerID, sampleID, ftID string) {
	t.Helper()
	dao := app.Dao()

	usersColl, _ := dao.FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	if err := user.SetEmail("enrich-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com"); err != nil {
		t.Fatalf("set email: %v", err)
	}
	if err := user.SetUsername("enrichuser_" + strings.ReplaceAll(t.Name(), "/", "_")); err != nil {
		t.Fatalf("set username: %v", err)
	}
	if err := user.SetPassword("test1234password"); err != nil {
		t.Fatalf("set password: %v", err)
	}
	if err := dao.SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}

	ftColl, _ := dao.FindCollectionByNameOrId("fieldtrips")
	ft := models.NewRecord(ftColl)
	ft.Set("owner", user.Id)
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	ft.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := dao.SaveRecord(ft); err != nil {
		t.Fatalf("save fieldtrip: %v", err)
	}

	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sam := models.NewRecord(samColl)
	sam.Set("owner", user.Id)
	sam.Set("fieldtrip", ft.Id)
	sam.Set("sample_id", "260519/1")
	sam.Set("latitude", lat)
	sam.Set("longitude", lon)
	sam.Set("begin_date", time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC))
	if err := dao.SaveRecord(sam); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	return user.Id, sam.Id, ft.Id
}

func TestEnricher_RunSafely_RecoversFromDownstreamPanic(t *testing.T) {
	app := newAppForRecordsOnly(t)

	// Wir provozieren einen Panic, indem wir ein nicht-existentes
	// Sample ID übergeben — der nachfolgende Code würde sonst auf nil
	// dereferenzieren. Tatsächlich loggt run() nur und kehrt zurück,
	// also testen wir: runSafely darf keinen Panic durch die
	// Goroutine-Grenze lassen, selbst wenn run() einen produziert.
	//
	// Falls run() je doch direkt paniken sollte: dieser Test fängt es.
	e := &Enricher{App: app}

	// kein t.Fatal hier — wir wollen, dass die Funktion sauber
	// zurückkehrt, ohne den Test zu reißen.
	done := make(chan struct{})
	go func() {
		defer close(done)
		e.runSafely("does-not-exist", "")
	}()
	select {
	case <-done:
		// gut: kein Panic durchgereicht
	case <-time.After(5 * time.Second):
		t.Fatal("runSafely hat nicht innerhalb von 5s zurückgekehrt")
	}
}

// ────────────────────────────────────────────────────────────────────
// Ortus-Anreicherung — httptest-Ortus mit den geteilten Testdaten
// ────────────────────────────────────────────────────────────────────

const ortusTestdata = "../../../shared/testdata/ortus/"

// Ochsenfurt-Koordinate aus query_de_ochsenfurt.json.
const (
	deLat = 49.681616
	deLon = 10.039652
)

// fakeOrtus serves one of the shared Ortus fixtures (regardless of the
// queried coordinate) and counts hits.
type fakeOrtus struct {
	srv     *httptest.Server
	fixture atomic.Value // string
	fail    atomic.Bool
	hits    atomic.Int64
}

func newFakeOrtus(t *testing.T, fixture string) *fakeOrtus {
	t.Helper()
	f := &fakeOrtus{}
	f.fixture.Store(fixture)
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		if f.fail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		raw, err := os.ReadFile(filepath.Join(ortusTestdata, f.fixture.Load().(string)))
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeOrtus) client() *services.Ortus {
	return &services.Ortus{
		BaseURL:    f.srv.URL,
		HTTPClient: &http.Client{Timeout: 2 * time.Second},
		MaxRetries: 1,
	}
}

func newOrtusEnricher(app *tests.TestApp, f *fakeOrtus) *Enricher {
	return &Enricher{App: app, Ortus: f.client(), Labels: adminlabels.Default(), Timeout: 5 * time.Second}
}

func runEnrich(t *testing.T, e *Enricher, sampleID string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	e.run(ctx, sampleID)
}

// fixturePlace maps a shared fixture onto its Place.
func fixturePlace(t *testing.T, name string, lat, lon float64) geoplace.Place {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(ortusTestdata, name))
	if err != nil {
		t.Fatal(err)
	}
	var r services.OrtusResponse
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatal(err)
	}
	res := geoplace.FromOrtus(&r, lat, lon, adminlabels.Default())
	if res.Place == nil {
		t.Fatalf("fixture %s has no place", name)
	}
	return *res.Place
}

func updateSample(t *testing.T, app *tests.TestApp, id string, fields map[string]any) {
	t.Helper()
	rec, err := app.Dao().FindRecordById("samples", id)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range fields {
		rec.Set(k, v)
	}
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
}

func loadSample(t *testing.T, app *tests.TestApp, id string) *models.Record {
	t.Helper()
	rec, err := app.Dao().FindRecordById("samples", id)
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

func sampleFeatures(t *testing.T, app *tests.TestApp, id string) []*models.Record {
	t.Helper()
	recs, err := app.Dao().FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0,
		map[string]any{"s": id})
	if err != nil {
		t.Fatal(err)
	}
	return recs
}

func TestEnrich_PendingGetsPlacemarkFeaturesMTB(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{"location_status": "pending"})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	if got := s.GetString("location_status"); got != "backend_service" {
		t.Errorf("location_status = %q, want backend_service", got)
	}
	pmID := s.GetString("placemark")
	if pmID == "" {
		t.Fatal("placemark not set")
	}
	pm, err := app.Dao().FindRecordById("placemarks", pmID)
	if err != nil {
		t.Fatal(err)
	}
	if got := pm.GetString("admin_municipality"); got != "Ochsenfurt" {
		t.Errorf("placemark.admin_municipality = %q, want Ochsenfurt", got)
	}
	if got := pm.GetString("geocoding_source"); got != "backend_service" {
		t.Errorf("placemark.geocoding_source = %q, want backend_service", got)
	}
	if got := pm.GetString("owner"); got != "" {
		t.Errorf("placemark.owner = %q, want empty (shared backend_service placemark)", got)
	}
	if got := s.GetString("placemark_suggestion"); got != "" {
		t.Errorf("placemark_suggestion = %q, want empty", got)
	}
	if got := s.GetString("mtb_sheet_number"); got != "6326" {
		t.Errorf("mtb_sheet_number = %q, want 6326", got)
	}
	if got := s.GetString("mtb_sheet_name"); got != "Ochsenfurt" {
		t.Errorf("mtb_sheet_name = %q, want Ochsenfurt", got)
	}
	if got := s.GetInt("mtb_quadrant"); got != 1 {
		t.Errorf("mtb_quadrant = %d, want 1", got)
	}
	if got := s.GetString("bearing_label"); got != "2 km WNW Ochsenfurt" {
		t.Errorf("bearing_label = %q", got)
	}
	if got := s.GetFloat("slope_deg"); got != 8.4 {
		t.Errorf("slope_deg = %v, want 8.4", got)
	}
	feats := sampleFeatures(t, app, sampleID)
	if len(feats) != 2 {
		t.Fatalf("features = %d, want 2", len(feats))
	}
	for _, fr := range feats {
		if got := fr.GetString("owner"); got != ownerID {
			t.Errorf("feature owner = %q, want sample owner %q", got, ownerID)
		}
	}
	if f.hits.Load() != 1 {
		t.Errorf("ortus hits = %d, want 1", f.hits.Load())
	}
}

func TestEnrich_EmptyStatusTreatedAsPending(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	if got := s.GetString("location_status"); got != "backend_service" {
		t.Errorf("location_status = %q, want backend_service", got)
	}
	if s.GetString("placemark") == "" {
		t.Error("placemark not set")
	}
}

func TestEnrich_InheritedDifferentPlaceSplits(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)

	// Placemark A: the inherited one from the previous sample (La Palma).
	a, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
		fixturePlace(t, "query_es_lapalma.json", 28.6835, -17.7642), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	updateSample(t, app, sampleID, map[string]any{
		"location_status":      "inherited",
		"placemark":            a.Id,
		"placemark_suggestion": a.Id,
	})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	b := s.GetString("placemark")
	if b == "" || b == a.Id {
		t.Fatalf("placemark = %q, want a new placemark B != A (%q)", b, a.Id)
	}
	pm, _ := app.Dao().FindRecordById("placemarks", b)
	if got := pm.GetString("admin_municipality"); got != "Ochsenfurt" {
		t.Errorf("placemark B municipality = %q, want Ochsenfurt", got)
	}
	if got := s.GetString("location_status"); got != "backend_service" {
		t.Errorf("location_status = %q, want backend_service", got)
	}
	if got := s.GetString("placemark_suggestion"); got != "" {
		t.Errorf("placemark_suggestion = %q, want empty", got)
	}
}

func TestEnrich_ManualOnlySuggestion(t *testing.T) {
	t.Run("different place gets suggestion", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		m, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
			fixturePlace(t, "query_es_lapalma.json", 28.6835, -17.7642), "manual", ownerID)
		if err != nil {
			t.Fatal(err)
		}
		updateSample(t, app, sampleID, map[string]any{"location_status": "manual", "placemark": m.Id})

		f := newFakeOrtus(t, "query_de_ochsenfurt.json")
		runEnrich(t, newOrtusEnricher(app, f), sampleID)

		s := loadSample(t, app, sampleID)
		if got := s.GetString("placemark"); got != m.Id {
			t.Errorf("placemark = %q, want manual %q unchanged", got, m.Id)
		}
		if got := s.GetString("location_status"); got != "manual" {
			t.Errorf("location_status = %q, want manual", got)
		}
		sugID := s.GetString("placemark_suggestion")
		if sugID == "" || sugID == m.Id {
			t.Fatalf("placemark_suggestion = %q, want candidate", sugID)
		}
		sug, _ := app.Dao().FindRecordById("placemarks", sugID)
		if got := sug.GetString("admin_municipality"); got != "Ochsenfurt" {
			t.Errorf("suggestion municipality = %q, want Ochsenfurt", got)
		}
		if got := s.GetString("mtb_sheet_number"); got != "6326" {
			t.Errorf("mtb_sheet_number = %q, want 6326 (geo always written)", got)
		}
		if n := len(sampleFeatures(t, app, sampleID)); n != 2 {
			t.Errorf("features = %d, want 2", n)
		}
	})

	t.Run("same place clears suggestion", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		m, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
			fixturePlace(t, "query_de_ochsenfurt.json", deLat, deLon), "manual", ownerID)
		if err != nil {
			t.Fatal(err)
		}
		stale, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
			fixturePlace(t, "query_es_lapalma.json", 28.6835, -17.7642), "backend_service", "")
		if err != nil {
			t.Fatal(err)
		}
		updateSample(t, app, sampleID, map[string]any{
			"location_status":      "manual",
			"placemark":            m.Id,
			"placemark_suggestion": stale.Id,
		})

		f := newFakeOrtus(t, "query_de_ochsenfurt.json")
		runEnrich(t, newOrtusEnricher(app, f), sampleID)

		s := loadSample(t, app, sampleID)
		if got := s.GetString("placemark"); got != m.Id {
			t.Errorf("placemark = %q, want %q", got, m.Id)
		}
		if got := s.GetString("placemark_suggestion"); got != "" {
			t.Errorf("placemark_suggestion = %q, want empty", got)
		}
	})
}

func TestEnrich_BackendServiceSkipped(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{"location_status": "backend_service"})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	if n := f.hits.Load(); n != 0 {
		t.Errorf("ortus hits = %d, want 0", n)
	}
	s := loadSample(t, app, sampleID)
	if s.GetString("placemark") != "" || s.GetString("mtb_sheet_number") != "" {
		t.Error("sample was modified although status is backend_service")
	}
}

func TestEnrich_NoCoordinateSkipped(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, 0, 0)

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	if n := f.hits.Load(); n != 0 {
		t.Errorf("ortus hits = %d, want 0", n)
	}
}

func TestEnrich_OrtusDownLeavesSample(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{"location_status": "pending"})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	f.fail.Store(true)
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	if f.hits.Load() == 0 {
		t.Fatal("ortus was not called")
	}
	s := loadSample(t, app, sampleID)
	if got := s.GetString("location_status"); got != "pending" {
		t.Errorf("location_status = %q, want pending", got)
	}
	if s.GetString("placemark") != "" || s.GetString("mtb_sheet_number") != "" {
		t.Error("sample was modified after Ortus failure")
	}
	if n := len(sampleFeatures(t, app, sampleID)); n != 0 {
		t.Errorf("features = %d, want 0", n)
	}
}

func TestEnrich_SeaKeepsStatusWritesGeo(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, 40.0, -25.0)
	// Stale geo + features from an earlier coordinate must be replaced.
	updateSample(t, app, sampleID, map[string]any{"location_status": "pending", "mtb_sheet_number": "6326"})
	if err := geoplace.ReplaceFeatures(app.Dao(), sampleID, ownerID,
		[]geoplace.Feature{{SourceID: "old", Layer: "old", FeatureID: "1"}}); err != nil {
		t.Fatal(err)
	}

	f := newFakeOrtus(t, "query_sea.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	if got := s.GetString("location_status"); got != "pending" {
		t.Errorf("location_status = %q, want pending (no place at sea)", got)
	}
	if got := s.GetString("placemark"); got != "" {
		t.Errorf("placemark = %q, want empty", got)
	}
	if got := s.GetString("mtb_sheet_number"); got != "" {
		t.Errorf("mtb_sheet_number = %q, want cleared", got)
	}
	if n := len(sampleFeatures(t, app, sampleID)); n != 0 {
		t.Errorf("features = %d, want 0 (replaced by empty set)", n)
	}
}

func TestEnrich_ManualAtSeaClearsStaleSuggestion(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, 40.0, -25.0)
	m, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
		fixturePlace(t, "query_de_ochsenfurt.json", deLat, deLon), "manual", ownerID)
	if err != nil {
		t.Fatal(err)
	}
	stale, err := geoplace.LookupOrCreatePlacemark(app.Dao(),
		fixturePlace(t, "query_es_lapalma.json", 28.6835, -17.7642), "backend_service", "")
	if err != nil {
		t.Fatal(err)
	}
	updateSample(t, app, sampleID, map[string]any{
		"location_status":      "manual",
		"placemark":            m.Id,
		"placemark_suggestion": stale.Id,
	})

	f := newFakeOrtus(t, "query_sea.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	if got := s.GetString("placemark"); got != m.Id {
		t.Errorf("placemark = %q, want manual %q unchanged", got, m.Id)
	}
	if got := s.GetString("location_status"); got != "manual" {
		t.Errorf("location_status = %q, want manual", got)
	}
	if got := s.GetString("placemark_suggestion"); got != "" {
		t.Errorf("placemark_suggestion = %q, want cleared (no admin coverage)", got)
	}
}

func TestEnrich_DEMOnlyWhenNoElevationSource(t *testing.T) {
	t.Run("GPS height 0 m stays", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		updateSample(t, app, sampleID, map[string]any{
			"location_status":   "pending",
			"elevation":         0,
			"elevation_source":  "location_service",
			"vertical_accuracy": 7,
		})

		f := newFakeOrtus(t, "query_de_ochsenfurt.json")
		runEnrich(t, newOrtusEnricher(app, f), sampleID)

		s := loadSample(t, app, sampleID)
		if got := s.GetFloat("elevation"); got != 0 {
			t.Errorf("elevation = %v, want 0 (GPS height kept)", got)
		}
		if got := s.GetString("elevation_source"); got != "location_service" {
			t.Errorf("elevation_source = %q, want location_service", got)
		}
		if got := s.GetFloat("vertical_accuracy"); got != 7 {
			t.Errorf("vertical_accuracy = %v, want 7", got)
		}
	})

	t.Run("empty source takes DEM", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		updateSample(t, app, sampleID, map[string]any{"location_status": "pending"})

		f := newFakeOrtus(t, "query_de_ochsenfurt.json")
		runEnrich(t, newOrtusEnricher(app, f), sampleID)

		s := loadSample(t, app, sampleID)
		if got := s.GetFloat("elevation"); got != 236 {
			t.Errorf("elevation = %v, want 236", got)
		}
		if got := s.GetString("elevation_source"); got != "backend_service" {
			t.Errorf("elevation_source = %q, want backend_service", got)
		}
		if got := s.GetFloat("vertical_accuracy"); got != 4 {
			t.Errorf("vertical_accuracy = %v, want 4", got)
		}
	})
}

func TestEnrich_CoordUpdateRetriggers(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)

	rec := loadSample(t, app, sampleID) // OriginalCopy = DB state
	rec.Set("latitude", deLat+0.001)
	if !coordChanged(rec) {
		t.Error("latitude change by 0.001 must re-trigger enrichment")
	}

	rec = loadSample(t, app, sampleID)
	rec.Set("longitude", deLon-0.000001)
	if !coordChanged(rec) {
		t.Error("longitude change by 1e-6 must re-trigger enrichment")
	}

	rec = loadSample(t, app, sampleID)
	rec.Set("latitude", deLat+0.00000001)
	if coordChanged(rec) {
		t.Error("float noise below 1e-7 must not re-trigger enrichment")
	}
}

func TestEnrich_NotesUpdateDoesNotRetrigger(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)

	rec := loadSample(t, app, sampleID)
	rec.Set("notes", "Unter Steinen")
	if coordChanged(rec) {
		t.Error("notes-only update must not re-trigger enrichment")
	}
}

func TestEnrich_BumpsVersion(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{"location_status": "pending", "version": 3})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	got := loadSample(t, app, sampleID).GetInt("version")
	if got != 4 {
		t.Fatalf("version = %d, want 4 (bumped by the enrichment)", got)
	}
	// A client still holding version 3 pushes 3+1 = 4. The version
	// guard (hooks.enforceVersion) rejects incoming <= current with 409.
	if incoming := 3 + 1; incoming > got {
		t.Errorf("stale client push with version %d would pass the guard (current %d)", incoming, got)
	}
}

func TestEnrich_DEMRefreshesBackendServiceHeight(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	// DEM height from an earlier coordinate.
	updateSample(t, app, sampleID, map[string]any{
		"location_status":   "pending",
		"elevation":         500,
		"elevation_source":  "backend_service",
		"vertical_accuracy": 20,
	})

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)

	s := loadSample(t, app, sampleID)
	if got := s.GetFloat("elevation"); got != 236 {
		t.Errorf("elevation = %v, want 236 (DEM height refreshed)", got)
	}
	if got := s.GetString("elevation_source"); got != "backend_service" {
		t.Errorf("elevation_source = %q, want backend_service", got)
	}
	if got := s.GetFloat("vertical_accuracy"); got != 4 {
		t.Errorf("vertical_accuracy = %v, want 4", got)
	}
}

func TestApplyDEMHeight(t *testing.T) {
	app := newAppForRecordsOnly(t)
	coll, _ := app.Dao().FindCollectionByNameOrId("samples")
	dem := 236.0
	mk := func(source string) *models.Record {
		r := models.NewRecord(coll)
		r.Set("elevation", 100)
		r.Set("elevation_source", source)
		r.Set("vertical_accuracy", 9)
		return r
	}

	t.Run("nil accuracy clears vertical_accuracy", func(t *testing.T) {
		r := mk("backend_service")
		applyDEMHeight(r, geoplace.SampleGeo{ElevationDEM: &dem})
		if r.GetFloat("elevation") != 236 || r.GetFloat("vertical_accuracy") != 0 {
			t.Errorf("elevation=%v vertical_accuracy=%v, want 236/0",
				r.GetFloat("elevation"), r.GetFloat("vertical_accuracy"))
		}
	})
	for _, src := range []string{"location_service", "manual"} {
		t.Run(src+" protected", func(t *testing.T) {
			r := mk(src)
			applyDEMHeight(r, geoplace.SampleGeo{ElevationDEM: &dem})
			if r.GetFloat("elevation") != 100 || r.GetString("elevation_source") != src ||
				r.GetFloat("vertical_accuracy") != 9 {
				t.Errorf("%s height was modified", src)
			}
		})
	}
	t.Run("no DEM keeps height", func(t *testing.T) {
		r := mk("")
		applyDEMHeight(r, geoplace.SampleGeo{})
		if r.GetFloat("elevation") != 100 || r.GetString("elevation_source") != "" {
			t.Error("height modified without DEM value")
		}
	})
}

func TestLocationStatus_TrimsAndDefaults(t *testing.T) {
	app := newAppForRecordsOnly(t)
	coll, _ := app.Dao().FindCollectionByNameOrId("samples")
	cases := map[string]string{"": "pending", "  ": "pending", " manual ": "manual", "inherited": "inherited"}
	for in, want := range cases {
		r := models.NewRecord(coll)
		r.Set("location_status", in)
		if got := locationStatus(r); got != want {
			t.Errorf("locationStatus(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEnrich_SetsTimezoneUnlessManual(t *testing.T) {
	t.Run("device is replaced by location_service", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		updateSample(t, app, sampleID, map[string]any{
			"location_status": "pending", "timezone": "Atlantic/Canary", "timezone_source": "device",
			"collecting_day": "2026-05-19",
		})
		before := loadSample(t, app, sampleID)

		runEnrich(t, newOrtusEnricher(app, newFakeOrtus(t, "query_de_ochsenfurt.json")), sampleID)

		s := loadSample(t, app, sampleID)
		if got := s.GetString("timezone"); got != "Europe/Berlin" {
			t.Errorf("timezone = %q, want Europe/Berlin", got)
		}
		if got := s.GetString("timezone_source"); got != "location_service" {
			t.Errorf("timezone_source = %q, want location_service", got)
		}
		// timezone change must not touch day, trip or id
		if s.GetString("collecting_day") != before.GetString("collecting_day") ||
			s.GetString("fieldtrip") != ftID || s.GetString("sample_id") != before.GetString("sample_id") {
			t.Errorf("collecting_day/fieldtrip/sample_id changed: %v", s.PublicExport())
		}
		for _, fr := range sampleFeatures(t, app, sampleID) {
			if fr.GetString("source_id") == "timezones-2026a" {
				t.Error("timezone source stored as feature")
			}
		}
	})

	t.Run("manual stays", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		updateSample(t, app, sampleID, map[string]any{
			"location_status": "pending", "timezone": "Asia/Tokyo", "timezone_source": "manual",
		})

		runEnrich(t, newOrtusEnricher(app, newFakeOrtus(t, "query_de_ochsenfurt.json")), sampleID)

		s := loadSample(t, app, sampleID)
		if s.GetString("timezone") != "Asia/Tokyo" || s.GetString("timezone_source") != "manual" {
			t.Errorf("manual timezone changed: %q / %q", s.GetString("timezone"), s.GetString("timezone_source"))
		}
	})

	t.Run("no tzid leaves untouched", func(t *testing.T) {
		app := newAppForRecordsOnly(t)
		_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
		updateSample(t, app, sampleID, map[string]any{
			"location_status": "pending", "timezone": "Atlantic/Canary", "timezone_source": "device",
		})

		runEnrich(t, newOrtusEnricher(app, newFakeOrtus(t, "query_sea.json")), sampleID)

		s := loadSample(t, app, sampleID)
		if s.GetString("timezone") != "Atlantic/Canary" || s.GetString("timezone_source") != "device" {
			t.Errorf("timezone changed without tzid: %q / %q", s.GetString("timezone"), s.GetString("timezone_source"))
		}
	})
}
