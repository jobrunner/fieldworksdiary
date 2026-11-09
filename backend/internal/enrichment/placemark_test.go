package enrichment

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/pocketbase/models"
)

// ────────────────────────────────────────────────────────────────────
// PlacemarkDedupHash — pure function, no DB
// ────────────────────────────────────────────────────────────────────

func TestPlacemarkDedupHash_Stable(t *testing.T) {
	a := PlacemarkDedupHash("DE", "Bayern", "Würzburg", "97070")
	b := PlacemarkDedupHash("DE", "Bayern", "Würzburg", "97070")
	if a != b {
		t.Errorf("hash should be stable across calls: %s vs %s", a, b)
	}
}

func TestPlacemarkDedupHash_CaseInsensitive(t *testing.T) {
	if PlacemarkDedupHash("DE", "Bayern", "Würzburg", "") !=
		PlacemarkDedupHash("de", "BAYERN", "würzburg", "") {
		t.Error("hash must be case-insensitive")
	}
}

func TestPlacemarkDedupHash_WhitespaceTrimmed(t *testing.T) {
	if PlacemarkDedupHash("DE", "Bayern", "Würzburg", "") !=
		PlacemarkDedupHash("  DE ", "Bayern", " Würzburg", "") {
		t.Error("hash must trim whitespace per field")
	}
}

func TestPlacemarkDedupHash_NFC_NormalizesDecomposedUnicode(t *testing.T) {
	// "Würzburg" composed (single codepoint 0x00FC for ü).
	composed := "Würzburg"
	// "Würzburg" decomposed (u + combining diaeresis 0x0308).
	decomposed := "Würzburg"
	if PlacemarkDedupHash("DE", "Bayern", composed, "") !=
		PlacemarkDedupHash("DE", "Bayern", decomposed, "") {
		t.Error("NFC must collapse composed and decomposed forms")
	}
}

func TestPlacemarkDedupHash_DistinguishesFields(t *testing.T) {
	// Field order matters: shifting "Bayern" into the country slot
	// must produce a different hash, otherwise the algorithm would
	// collapse legitimately different placemarks.
	a := PlacemarkDedupHash("DE", "Bayern", "Würzburg", "")
	b := PlacemarkDedupHash("Bayern", "DE", "Würzburg", "")
	if a == b {
		t.Error("hash must distinguish field positions")
	}
}

func TestPlacemarkDedupHash_HexDigestLength(t *testing.T) {
	h := PlacemarkDedupHash("DE", "Bayern", "Würzburg", "97070")
	if len(h) != 64 {
		t.Errorf("SHA-256 hex digest length = %d, want 64", len(h))
	}
}

// TestPlacemarkDedupHash_LockedConstant pins the canonical input
// down to a precomputed digest. The matching constant lives in
// `internal/api/placemark_test.go` as
// `TestDedupHash_MatchesEnrichmentImplementation` — both tests
// must hold the same value, otherwise the api-side and
// enrichment-side hash functions have drifted.
func TestPlacemarkDedupHash_LockedConstant(t *testing.T) {
	const expected = "4b7015e1caea6410c452841f331eb3855010ee52d13d4c4573ca18f461c81fa7"
	got := PlacemarkDedupHash("DE", "Bayern", "Würzburg", "97070")
	if got != expected {
		t.Errorf("locked hash drift!\nwant: %s\ngot:  %s", expected, got)
	}
}

// ────────────────────────────────────────────────────────────────────
// PlacemarkEnricher.run — integration against TestApp
// ────────────────────────────────────────────────────────────────────

// fakeLabelloc spins up a httptest server that returns a fixed
// labelloc response. The Geocache hits it once per (lat, lon, lang)
// triple, so multiple test runs against the same coords go through
// the cache.
func fakeLabelloc(t *testing.T, locality string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{
				"country":    "Deutschland",
				"countryIso": "DE",
				"adminArea":  "Bayern",
				"adminArea2": "Unterfranken",
				"locality":   locality,
			},
			"status": map[string]any{"code": 200, "message": "OK"},
		})
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestPlacemarkEnricher_LookupOrCreateOnFirstRun(t *testing.T) {
	app := newAppForRecordsOnly(t)
	// Owner + locality via raw DAO so we don't trigger the create-hook
	// chain twice.
	usersColl, _ := app.Dao().FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	_ = user.SetEmail("pm-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com")
	_ = user.SetUsername("pmuser_" + strings.ReplaceAll(t.Name(), "/", "_"))
	_ = user.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}

	locColl, _ := app.Dao().FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", user.Id)
	loc.Set("name", "Test")
	loc.Set("latitude", 49.79)
	loc.Set("longitude", 9.94)
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	labelSrv := fakeLabelloc(t, "Würzburg")
	enricher := &PlacemarkEnricher{
		App: app,
		Labelloc: &services.Labelloc{
			BaseURL:    labelSrv.URL,
			HTTPClient: &http.Client{Timeout: 2 * time.Second},
			MaxRetries: 1,
		},
		Timeout: 5 * time.Second,
	}
	if err := enricher.run(loc.Id); err != nil {
		t.Fatalf("enricher.run: %v", err)
	}

	reloaded, err := app.Dao().FindRecordById("localities", loc.Id)
	if err != nil {
		t.Fatalf("re-fetch locality: %v", err)
	}
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
	if pm.GetString("locality") != "Würzburg" {
		t.Errorf("locality = %q, want Würzburg", pm.GetString("locality"))
	}
	if pm.GetString("geocoding_source") != "backend_service" {
		t.Errorf("geocoding_source = %q, want backend_service", pm.GetString("geocoding_source"))
	}
}

func TestPlacemarkEnricher_SharesPlacemarkAcrossLocalities(t *testing.T) {
	app := newAppForRecordsOnly(t)
	usersColl, _ := app.Dao().FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	_ = user.SetEmail("share-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com")
	_ = user.SetUsername("shareuser_" + strings.ReplaceAll(t.Name(), "/", "_"))
	_ = user.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}

	mkLocality := func(lat, lon float64) *models.Record {
		locColl, _ := app.Dao().FindCollectionByNameOrId("localities")
		loc := models.NewRecord(locColl)
		loc.Set("owner", user.Id)
		loc.Set("name", "Test")
		loc.Set("latitude", lat)
		loc.Set("longitude", lon)
		loc.Set("location_source", "user")
		loc.Set("version", 1)
		if err := app.Dao().SaveRecord(loc); err != nil {
			t.Fatalf("save locality: %v", err)
		}
		return loc
	}

	labelSrv := fakeLabelloc(t, "Würzburg")
	enricher := &PlacemarkEnricher{
		App: app,
		Labelloc: &services.Labelloc{
			BaseURL:    labelSrv.URL,
			HTTPClient: &http.Client{Timeout: 2 * time.Second},
			MaxRetries: 1,
		},
		Timeout: 5 * time.Second,
	}

	// Two distinct coords (so the geocache doesn't pre-empt the
	// fake) but the same labelloc result → same dedup_hash → same
	// placemark id on both localities.
	a := mkLocality(49.790, 9.940)
	b := mkLocality(49.795, 9.950)
	if err := enricher.run(a.Id); err != nil {
		t.Fatalf("enrich a: %v", err)
	}
	if err := enricher.run(b.Id); err != nil {
		t.Fatalf("enrich b: %v", err)
	}

	aReloaded, _ := app.Dao().FindRecordById("localities", a.Id)
	bReloaded, _ := app.Dao().FindRecordById("localities", b.Id)
	if aReloaded.GetString("placemark") == "" || bReloaded.GetString("placemark") == "" {
		t.Fatal("placemark relation missing on one of them")
	}
	if aReloaded.GetString("placemark") != bReloaded.GetString("placemark") {
		t.Errorf("expected shared placemark, got %q vs %q",
			aReloaded.GetString("placemark"),
			bReloaded.GetString("placemark"))
	}
}

func TestPlacemarkEnricher_RespectsManualOverride(t *testing.T) {
	app := newAppForRecordsOnly(t)
	usersColl, _ := app.Dao().FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	_ = user.SetEmail("manual-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com")
	_ = user.SetUsername("manualuser_" + strings.ReplaceAll(t.Name(), "/", "_"))
	_ = user.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}

	// Hand-crafted placemark with geocoding_source = manual.
	pmColl, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	manual := models.NewRecord(pmColl)
	manual.Set("country", "FR")
	manual.Set("locality", "Paris")
	manual.Set("geocoding_source", "manual")
	manual.Set("dedup_hash", PlacemarkDedupHash("FR", "", "Paris", ""))
	if err := app.Dao().SaveRecord(manual); err != nil {
		t.Fatalf("save manual placemark: %v", err)
	}

	locColl, _ := app.Dao().FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", user.Id)
	loc.Set("name", "Test")
	loc.Set("latitude", 49.79)
	loc.Set("longitude", 9.94)
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	loc.Set("placemark", manual.Id)
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	labelSrv := fakeLabelloc(t, "Würzburg")
	enricher := &PlacemarkEnricher{
		App: app,
		Labelloc: &services.Labelloc{
			BaseURL:    labelSrv.URL,
			HTTPClient: &http.Client{Timeout: 2 * time.Second},
			MaxRetries: 1,
		},
		Timeout: 5 * time.Second,
	}
	if err := enricher.run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}

	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != manual.Id {
		t.Errorf("manual override was overwritten — placemark = %q, want %q",
			reloaded.GetString("placemark"), manual.Id)
	}
}

func TestPlacemarkEnricher_NoCoordsIsNoOp(t *testing.T) {
	app := newAppForRecordsOnly(t)
	usersColl, _ := app.Dao().FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	_ = user.SetEmail("nocoord-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com")
	_ = user.SetUsername("nocoorduser_" + strings.ReplaceAll(t.Name(), "/", "_"))
	_ = user.SetPassword("test1234password")
	if err := app.Dao().SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}
	locColl, _ := app.Dao().FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", user.Id)
	loc.Set("name", "Test")
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	// no lat/lon
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	enricher := &PlacemarkEnricher{App: app}
	if err := enricher.run(loc.Id); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	reloaded, _ := app.Dao().FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != "" {
		t.Error("a coordinate-less locality should not get a placemark")
	}
}
