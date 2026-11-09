package enrichment

import (
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

func newPlacemarkEnricher(app *tests.TestApp, f *fakeOrtus) *PlacemarkEnricher {
	return &PlacemarkEnricher{App: app, Ortus: f.client(), Labels: adminlabels.Default(), Timeout: 5 * time.Second}
}

func createPMUser(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	usersColl, _ := app.Dao().FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	n := strings.ReplaceAll(t.Name(), "/", "_")
	_ = user.SetEmail("pm-" + n + "@example.com")
	_ = user.SetUsername("pmuser_" + n)
	_ = user.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return user
}

func createLocality(t *testing.T, app *tests.TestApp, ownerID string, lat, lon float64, placemarkID string) *models.Record {
	t.Helper()
	locColl, _ := app.Dao().FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", ownerID)
	loc.Set("name", "Test")
	loc.Set("latitude", lat)
	loc.Set("longitude", lon)
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	if placemarkID != "" {
		loc.Set("placemark", placemarkID)
	}
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}
	return loc
}

func TestPlacemarkEnricher_LookupOrCreateOnFirstRun(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	loc := createLocality(t, app, user.Id, deLat, deLon, "")

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err != nil {
		t.Fatalf("enricher.run: %v", err)
	}

	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	pmID := reloaded.GetString("placemark")
	if pmID == "" {
		t.Fatal("placemark relation not set after enrich")
	}
	pm, err := app.Dao().FindRecordById("placemarks", pmID)
	if err != nil {
		t.Fatalf("placemark vanished: %v", err)
	}
	if pm.GetString("country") != "DE" {
		t.Errorf("country = %q, want DE", pm.GetString("country"))
	}
	if got := pm.GetString("admin_municipality"); got != "Ochsenfurt" {
		t.Errorf("admin_municipality = %q, want Ochsenfurt", got)
	}
	if pm.GetString("geocoding_source") != "backend_service" {
		t.Errorf("geocoding_source = %q, want backend_service", pm.GetString("geocoding_source"))
	}
}

func TestPlacemarkEnricher_SharesPlacemarkAcrossLocalities(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	enricher := newPlacemarkEnricher(app, f)

	a := createLocality(t, app, user.Id, deLat, deLon, "")
	b := createLocality(t, app, user.Id, deLat+0.001, deLon+0.001, "")
	if err := enricher.run(a.Id); err != nil {
		t.Fatalf("enrich a: %v", err)
	}
	if err := enricher.run(b.Id); err != nil {
		t.Fatalf("enrich b: %v", err)
	}
	aR, _ := app.Dao().FindRecordById("localities", a.Id)
	bR, _ := app.Dao().FindRecordById("localities", b.Id)
	if aR.GetString("placemark") == "" || aR.GetString("placemark") != bR.GetString("placemark") {
		t.Errorf("expected shared placemark, got %q vs %q", aR.GetString("placemark"), bR.GetString("placemark"))
	}
}

func TestLocalityPlacemark_SharesRecordWithSample(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{"location_status": "pending"})
	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	runEnrich(t, newOrtusEnricher(app, f), sampleID)
	samplePM := loadSample(t, app, sampleID).GetString("placemark")
	if samplePM == "" {
		t.Fatal("sample got no placemark")
	}

	loc := createLocality(t, app, ownerID, deLat, deLon, "")
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err != nil {
		t.Fatalf("enrich locality: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if got := reloaded.GetString("placemark"); got != samplePM {
		t.Errorf("locality placemark = %q, want sample's %q", got, samplePM)
	}
}

func TestPlacemarkEnricher_RespectsManualOverride(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)

	pmColl, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	manual := models.NewRecord(pmColl)
	manual.Set("country", "FR")
	manual.Set("locality", "Paris")
	manual.Set("geocoding_source", "manual")
	manual.Set("dedup_hash", "manual-test-hash")
	if err := app.Dao().SaveRecord(manual); err != nil {
		t.Fatalf("save manual placemark: %v", err)
	}
	loc := createLocality(t, app, user.Id, deLat, deLon, manual.Id)

	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != manual.Id {
		t.Errorf("manual override was overwritten — placemark = %q, want %q",
			reloaded.GetString("placemark"), manual.Id)
	}
	if f.hits.Load() != 0 {
		t.Errorf("ortus hit %d times for a manual placemark, want 0", f.hits.Load())
	}
}

func TestPlacemarkEnricher_SeaLeavesLocalityUntouched(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	loc := createLocality(t, app, user.Id, 40.0, -25.0, "")
	f := newFakeOrtus(t, "query_sea.json")
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != "" {
		t.Error("sea locality should not get a placemark")
	}
}

func TestPlacemarkEnricher_OrtusDownReturnsError(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	loc := createLocality(t, app, user.Id, deLat, deLon, "")
	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	f.fail.Store(true)
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err == nil {
		t.Error("want error when Ortus fails")
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != "" {
		t.Error("placemark must stay empty")
	}
}

func TestPlacemarkEnricher_NilOrtusIsNoOp(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	loc := createLocality(t, app, user.Id, deLat, deLon, "")
	if err := (&PlacemarkEnricher{App: app}).run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != "" {
		t.Error("nil Ortus should not set a placemark")
	}
}

func TestPlacemarkEnricher_NoCoordsIsNoOp(t *testing.T) {
	app := newAppForRecordsOnly(t)
	user := createPMUser(t, app)
	loc := createLocality(t, app, user.Id, 0, 0, "")
	f := newFakeOrtus(t, "query_de_ochsenfurt.json")
	if err := newPlacemarkEnricher(app, f).run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != "" {
		t.Error("a coordinate-less locality should not get a placemark")
	}
	if f.hits.Load() != 0 {
		t.Error("Ortus must not be queried without a coordinate")
	}
}
