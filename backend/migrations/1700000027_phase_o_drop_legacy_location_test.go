package migrations

import (
	"fmt"
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/forms"
	"github.com/pocketbase/pocketbase/models"
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

func TestDropLegacyLocation_UpMapsLegacyManualPlacemarks(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()
	db := dao.DB()
	users, _ := dao.FindCollectionByNameOrId("users")
	var owners []string
	for _, n := range []string{"legacya", "legacyb"} {
		u := models.NewRecord(users)
		_ = u.SetEmail(n + "@example.com")
		_ = u.SetUsername(n)
		_ = u.SetPassword("test1234password")
		if err := dao.SaveRecord(u); err != nil {
			t.Fatal(err)
		}
		owners = append(owners, u.Id)
	}
	// Pre-O shared manual placemark: only legacy columns, no owner.
	phaseZExec(t, db, `INSERT INTO placemarks (id, country, administrative_area, sub_administrative_area,
		locality, sub_locality, postal_code, name, thoroughfare, geocoding_source, dedup_hash, created, updated)
		VALUES ('pmlegacy0000001', 'DE', 'Bayern', 'Unterfranken', 'Würzburg', 'Heidingsfeld', '97084',
		'Hexenbruch', 'Am Weg', 'manual', 'legacyhash', '2024-01-01 00:00:00.000Z', '2024-01-01 00:00:00.000Z')`, nil)
	for i, o := range owners {
		phaseZExec(t, db, `INSERT INTO localities (id, owner, name, latitude, longitude, placemark, version, created, updated)
			VALUES ({:id}, {:o}, 'Ort', 49.7, 9.9, 'pmlegacy0000001', 1, {:c}, {:c})`,
			dbx.Params{"id": fmt.Sprintf("loclegacy00000%d", i+1), "o": o,
				"c": fmt.Sprintf("2024-01-0%d 00:00:00.000Z", i+2)})
	}

	if err := dropLegacyLocationUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}

	pmA, _ := dao.FindRecordById("localities", "loclegacy000001")
	pmB, _ := dao.FindRecordById("localities", "loclegacy000002")
	if pmA.GetString("placemark") != "pmlegacy0000001" {
		t.Errorf("owner A moved away from the original placemark: %q", pmA.GetString("placemark"))
	}
	if pmB.GetString("placemark") == "pmlegacy0000001" || pmB.GetString("placemark") == "" {
		t.Fatalf("owner B got no clone: %q", pmB.GetString("placemark"))
	}
	if pmB.GetInt("version") != 2 {
		t.Errorf("owner B locality version = %d, want 2", pmB.GetInt("version"))
	}
	for id, owner := range map[string]string{
		"pmlegacy0000001": owners[0], pmB.GetString("placemark"): owners[1],
	} {
		pm, err := dao.FindRecordById("placemarks", id)
		if err != nil {
			t.Fatal(err)
		}
		for col, want := range map[string]string{
			"owner": owner, "geocoding_source": "manual", "country_iso": "DE",
			"admin_state": "Bayern", "admin_county": "Unterfranken",
			"admin_municipality": "Würzburg", "admin_submunicipality": "Heidingsfeld",
		} {
			if got := pm.GetString(col); got != want {
				t.Errorf("placemark %s: %s = %q, want %q", id, col, got, want)
			}
		}
		if pm.GetString("dedup_hash") == "legacyhash" {
			t.Errorf("placemark %s: dedup_hash not recomputed", id)
		}
	}
	coll, _ := dao.FindCollectionByNameOrId("placemarks")
	for _, f := range legacyLocationFields["placemarks"] {
		if coll.Schema.GetFieldByName(f) != nil {
			t.Errorf("placemarks.%s still present", f)
		}
	}
}

func TestDropLegacyLocation_DownRestoresOptionalColumns(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app.Dao()
	coll, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range legacyLocationFields["placemarks"] {
		sf := coll.Schema.GetFieldByName(f)
		if sf == nil {
			t.Fatalf("placemarks.%s not restored", f)
		}
		if sf.Required {
			t.Errorf("placemarks.%s restored as required", f)
		}
	}
	// A placemark created after Down (no legacy country) must validate.
	rec := models.NewRecord(coll)
	rec.Set("geocoding_source", "backend_service")
	rec.Set("country_iso", "DE")
	rec.Set("dedup_hash", "downhash")
	if err := forms.NewRecordUpsert(app, rec).Submit(); err != nil {
		t.Errorf("placemark without legacy country rejected after down: %v", err)
	}
	// Down is idempotent.
	if err := dropLegacyLocationDown(dao.DB()); err != nil {
		t.Errorf("second down: %v", err)
	}
}
