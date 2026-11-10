package migrations

import (
	"testing"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// The migration itself runs automatically on `tests.NewTestApp()`,
// so we can't observe its empty-DB run directly. We test the
// extracted helper `backfillOnePlacemark` against synthetic
// sample rows we create *after* migration time.

func setupTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

func TestBackfillDedupHash_Stable(t *testing.T) {
	a := backfillDedupHash("DE", "Bayern", "Würzburg", "97070")
	b := backfillDedupHash("DE", "Bayern", "Würzburg", "97070")
	if a != b {
		t.Errorf("hash should be stable: %s vs %s", a, b)
	}
}

// TestBackfillDedupHash_LockedConstant pins the canonical input
// to the same precomputed SHA-256 that the enrichment + api copies
// of this function pin. If any of the three drift apart we'd lose
// dedup consistency across the auto-geocode hook (R7.1), the
// manual-override endpoint (R7.2), and this backfill (R7.3).
func TestBackfillDedupHash_LockedConstant(t *testing.T) {
	const expected = "4b7015e1caea6410c452841f331eb3855010ee52d13d4c4573ca18f461c81fa7"
	got := backfillDedupHash("DE", "Bayern", "Würzburg", "97070")
	if got != expected {
		t.Errorf("backfill hash drifted!\nwant: %s\ngot:  %s", expected, got)
	}
}

func TestBackfillOnePlacemark_CreatesAndAttaches(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()

	// Seed an owner + locality (no placemark yet).
	userColl, _ := dao.FindCollectionByNameOrId("users")
	owner := models.NewRecord(userColl)
	_ = owner.SetEmail("backfill@example.com")
	_ = owner.SetUsername("backfilluser")
	_ = owner.SetPassword("test1234password")
	if err := dao.SaveRecord(owner); err != nil {
		t.Fatalf("save owner: %v", err)
	}

	locColl, _ := dao.FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", owner.Id)
	loc.Set("name", "Test")
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	if err := dao.SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	// Seed a sample with a legacy admin_units JSON snapshot, pointed
	// at the locality.
	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sample := models.NewRecord(samColl)
	sample.Set("owner", owner.Id)
	sample.Set("sample_id", "260519/1")
	sample.Set("latitude", 49.79)
	sample.Set("longitude", 9.94)
	sample.Set("collecting_day", "2026-05-19")
	sample.Set("location_source", "location_service")
	sample.Set("time_zone", "Europe/Berlin")
	sample.Set("version", 1)
	sample.Set("locality", loc.Id)
	sample.Set("admin_units", `{"country":"Deutschland","countryIso":"DE","adminArea":"Bayern","adminArea2":"Unterfranken","locality":"Würzburg"}`)
	if err := dao.SaveRecord(sample); err != nil {
		t.Fatalf("save sample: %v", err)
	}

	if err := backfillOnePlacemark(dao, sample); err != nil {
		t.Fatalf("backfillOnePlacemark: %v", err)
	}

	// Locality now points at a placemark.
	reloaded, err := dao.FindRecordById("localities", loc.Id)
	if err != nil {
		t.Fatalf("re-fetch locality: %v", err)
	}
	pmID := reloaded.GetString("placemark")
	if pmID == "" {
		t.Fatal("placemark relation not attached")
	}
	pm, err := dao.FindRecordById("placemarks", pmID)
	if err != nil {
		t.Fatalf("placemark missing: %v", err)
	}
	if pm.GetString("country") != "DE" {
		t.Errorf("country = %q, want DE", pm.GetString("country"))
	}
	if pm.GetString("locality") != "Würzburg" {
		t.Errorf("locality = %q, want Würzburg", pm.GetString("locality"))
	}
	if pm.GetString("geocoding_source") != "backend-service" {
		t.Errorf("geocoding_source = %q, want backend-service", pm.GetString("geocoding_source"))
	}
}

func TestBackfillOnePlacemark_IdempotentOnRerun(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()

	userColl, _ := dao.FindCollectionByNameOrId("users")
	owner := models.NewRecord(userColl)
	_ = owner.SetEmail("idemp@example.com")
	_ = owner.SetUsername("idempuser")
	_ = owner.SetPassword("test1234password")
	if err := dao.SaveRecord(owner); err != nil {
		t.Fatalf("save owner: %v", err)
	}

	locColl, _ := dao.FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", owner.Id)
	loc.Set("name", "Test")
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	if err := dao.SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sample := models.NewRecord(samColl)
	sample.Set("owner", owner.Id)
	sample.Set("sample_id", "260519/1")
	sample.Set("latitude", 49.79)
	sample.Set("longitude", 9.94)
	sample.Set("collecting_day", "2026-05-19")
	sample.Set("location_source", "location_service")
	sample.Set("time_zone", "Europe/Berlin")
	sample.Set("version", 1)
	sample.Set("locality", loc.Id)
	sample.Set("admin_units", `{"countryIso":"DE","adminArea":"Bayern","locality":"Würzburg"}`)
	if err := dao.SaveRecord(sample); err != nil {
		t.Fatalf("save sample: %v", err)
	}

	if err := backfillOnePlacemark(dao, sample); err != nil {
		t.Fatalf("first run: %v", err)
	}
	if err := backfillOnePlacemark(dao, sample); err != nil {
		t.Fatalf("second run: %v", err)
	}

	pms, err := dao.FindRecordsByFilter("placemarks", "country = 'DE'", "", 0, 0)
	if err != nil {
		t.Fatalf("count placemarks: %v", err)
	}
	if len(pms) != 1 {
		t.Errorf("expected exactly 1 placemark after re-run, got %d", len(pms))
	}
}

func TestBackfillOnePlacemark_SkipsManualOverride(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()

	userColl, _ := dao.FindCollectionByNameOrId("users")
	owner := models.NewRecord(userColl)
	_ = owner.SetEmail("manual@example.com")
	_ = owner.SetUsername("manualuser")
	_ = owner.SetPassword("test1234password")
	if err := dao.SaveRecord(owner); err != nil {
		t.Fatalf("save owner: %v", err)
	}

	// Locality already has a hand-edited placemark — backfill must
	// not overwrite it.
	pmColl, _ := dao.FindCollectionByNameOrId("placemarks")
	manual := models.NewRecord(pmColl)
	manual.Set("country", "FR")
	manual.Set("locality", "Paris")
	manual.Set("geocoding_source", "manual")
	manual.Set("dedup_hash", "deadbeef")
	if err := dao.SaveRecord(manual); err != nil {
		t.Fatalf("save manual placemark: %v", err)
	}

	locColl, _ := dao.FindCollectionByNameOrId("localities")
	loc := models.NewRecord(locColl)
	loc.Set("owner", owner.Id)
	loc.Set("name", "Test")
	loc.Set("location_source", "user")
	loc.Set("version", 1)
	loc.Set("placemark", manual.Id)
	if err := dao.SaveRecord(loc); err != nil {
		t.Fatalf("save locality: %v", err)
	}

	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sample := models.NewRecord(samColl)
	sample.Set("owner", owner.Id)
	sample.Set("sample_id", "260519/1")
	sample.Set("latitude", 49.79)
	sample.Set("longitude", 9.94)
	sample.Set("collecting_day", "2026-05-19")
	sample.Set("location_source", "location_service")
	sample.Set("time_zone", "Europe/Berlin")
	sample.Set("version", 1)
	sample.Set("locality", loc.Id)
	sample.Set("admin_units", `{"countryIso":"DE","adminArea":"Bayern","locality":"Würzburg"}`)
	if err := dao.SaveRecord(sample); err != nil {
		t.Fatalf("save sample: %v", err)
	}

	if err := backfillOnePlacemark(dao, sample); err != nil {
		t.Fatalf("backfillOnePlacemark: %v", err)
	}

	reloaded, _ := dao.FindRecordById("localities", loc.Id)
	if reloaded.GetString("placemark") != manual.Id {
		t.Errorf("manual override clobbered: got %q, want %q",
			reloaded.GetString("placemark"), manual.Id)
	}
}

func TestBackfillOnePlacemark_TolerantOfMalformedJSON(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()

	userColl, _ := dao.FindCollectionByNameOrId("users")
	owner := models.NewRecord(userColl)
	_ = owner.SetEmail("mal@example.com")
	_ = owner.SetUsername("maluser")
	_ = owner.SetPassword("test1234password")
	if err := dao.SaveRecord(owner); err != nil {
		t.Fatalf("save owner: %v", err)
	}
	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sample := models.NewRecord(samColl)
	sample.Set("owner", owner.Id)
	sample.Set("sample_id", "260519/1")
	sample.Set("latitude", 49.79)
	sample.Set("longitude", 9.94)
	sample.Set("collecting_day", "2026-05-19")
	sample.Set("location_source", "location_service")
	sample.Set("time_zone", "Europe/Berlin")
	sample.Set("version", 1)
	sample.Set("admin_units", `{not-json`)
	if err := dao.SaveRecord(sample); err != nil {
		t.Fatalf("save sample: %v", err)
	}

	// Must not error — malformed snapshots silently skip.
	if err := backfillOnePlacemark(dao, sample); err != nil {
		t.Errorf("malformed JSON should be a silent skip, got: %v", err)
	}
}
