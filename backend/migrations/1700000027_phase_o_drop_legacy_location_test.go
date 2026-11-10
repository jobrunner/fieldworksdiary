package migrations

import (
	"testing"

	"github.com/pocketbase/pocketbase/tests"
)

// setupLegacyLocationTestApp boots a test app and rolls the O3 drop back,
// so tests of earlier migrations can seed the legacy columns.
func setupLegacyLocationTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app := setupTestApp(t)
	if err := dropLegacyLocationDown(app.Dao().DB()); err != nil {
		t.Fatalf("restore legacy columns: %v", err)
	}
	return app
}

func TestDropLegacyLocation_ColumnsGoneNewDataKept(t *testing.T) {
	app := setupTestApp(t)
	dao := app.Dao()
	db := dao.DB()
	// The test app already ran Up. Roll back to the legacy shape, seed
	// both legacy and new columns, then run Up again.
	if err := dropLegacyLocationDown(db); err != nil {
		t.Fatalf("down: %v", err)
	}
	for _, c := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, _ := dao.FindCollectionByNameOrId(c)
		for _, f := range legacyLocationFields[c] {
			if coll.Schema.GetFieldByName(f) == nil {
				t.Fatalf("%s.%s not restored by down", c, f)
			}
		}
	}
	if _, err := dao.FindCollectionByNameOrId("sample_sequences"); err != nil {
		t.Fatalf("sample_sequences not restored: %v", err)
	}
	phaseZExec(t, db, `INSERT INTO placemarks (id, country, locality, country_iso, admin_state, dedup_hash, geocoding_source)
		VALUES ('pmdrop000000001', 'DE', 'Würzburg', 'DE', 'Bayern', 'h', 'manual')`, nil)
	phaseZExec(t, db, `INSERT INTO samples (id, mtb, mtb_sheet_number) VALUES ('smdrop000000001', '{"x":1}', '6326')`, nil)
	phaseZExec(t, db, `INSERT INTO fieldtrips (id, country, admin_area) VALUES ('ftdrop000000001', 'DE', 'Bayern')`, nil)

	if err := dropLegacyLocationUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}
	for _, c := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, _ := dao.FindCollectionByNameOrId(c)
		for _, f := range legacyLocationFields[c] {
			if coll.Schema.GetFieldByName(f) != nil {
				t.Errorf("%s.%s still present", c, f)
			}
		}
	}
	if _, err := dao.FindCollectionByNameOrId("sample_sequences"); err == nil {
		t.Errorf("sample_sequences still present")
	}
	var iso, state string
	if err := db.NewQuery(`SELECT country_iso, admin_state FROM placemarks WHERE id='pmdrop000000001'`).Row(&iso, &state); err != nil {
		t.Fatal(err)
	}
	if iso != "DE" || state != "Bayern" {
		t.Errorf("placemark new columns = %q %q", iso, state)
	}
	var sheet string
	if err := db.NewQuery(`SELECT mtb_sheet_number FROM samples WHERE id='smdrop000000001'`).Row(&sheet); err != nil {
		t.Fatal(err)
	}
	if sheet != "6326" {
		t.Errorf("mtb_sheet_number = %q", sheet)
	}
}
