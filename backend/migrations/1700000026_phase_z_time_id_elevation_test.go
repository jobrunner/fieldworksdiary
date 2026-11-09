package migrations

import (
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/tests"
)

// phaseZRollback reverts the Phase Z migration so a test can seed
// legacy-shaped rows and then run the Up path on them.
func phaseZRollback(t *testing.T, app *tests.TestApp) *daos.Dao {
	t.Helper()
	dao := app.Dao()
	if err := phaseZDown(dao.DB()); err != nil {
		t.Fatalf("down: %v", err)
	}
	return dao
}

func phaseZExec(t *testing.T, db dbx.Builder, q string, p dbx.Params) {
	t.Helper()
	if _, err := db.NewQuery(q).Bind(p).Execute(); err != nil {
		t.Fatalf("exec %q: %v", q, err)
	}
}

func TestPhaseZ_RenamesTimeZone(t *testing.T) {
	app := setupTestApp(t)
	dao := phaseZRollback(t, app)
	phaseZExec(t, dao.DB(), `INSERT INTO samples (id, time_zone) VALUES ('smpz00000000001', 'Atlantic/Canary')`, nil)
	if err := phaseZUp(dao.DB()); err != nil {
		t.Fatalf("up: %v", err)
	}
	s, _ := dao.FindCollectionByNameOrId("samples")
	if s.Schema.GetFieldByName("time_zone") != nil || s.Schema.GetFieldByName("timezone") == nil {
		t.Fatalf("rename not applied")
	}
	var tz string
	if err := dao.DB().NewQuery(`SELECT timezone FROM samples WHERE id='smpz00000000001'`).Row(&tz); err != nil {
		t.Fatal(err)
	}
	if tz != "Atlantic/Canary" {
		t.Errorf("timezone = %q", tz)
	}
}

func TestPhaseZ_MovesDEMIntoElevation(t *testing.T) {
	app := setupTestApp(t)
	dao := phaseZRollback(t, app)
	db := dao.DB()
	phaseZExec(t, db, `INSERT INTO samples (id, elevation, elevation_source, elevation_dem, elevation_dem_accuracy)
		VALUES ('smpz00000000001', 0, '', 1147, 4), ('smpz00000000002', 0, 'location_service', 12, 3)`, nil)
	if err := phaseZUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}
	var elev, acc float64
	var src string
	if err := db.NewQuery(`SELECT elevation, vertical_accuracy, elevation_source FROM samples WHERE id='smpz00000000001'`).
		Row(&elev, &acc, &src); err != nil {
		t.Fatal(err)
	}
	if elev != 1147 || acc != 4 || src != "backend_service" {
		t.Errorf("row1 = %v %v %q", elev, acc, src)
	}
	if err := db.NewQuery(`SELECT elevation, elevation_source FROM samples WHERE id='smpz00000000002'`).
		Row(&elev, &src); err != nil {
		t.Fatal(err)
	}
	if elev != 0 || src != "location_service" {
		t.Errorf("row2 = %v %q", elev, src)
	}
	s, _ := dao.FindCollectionByNameOrId("samples")
	for _, n := range []string{"elevation_dem", "elevation_dem_accuracy"} {
		if s.Schema.GetFieldByName(n) != nil {
			t.Errorf("%s still present", n)
		}
	}
}

func TestPhaseZ_SuffixesExistingDuplicates(t *testing.T) {
	app := setupTestApp(t)
	dao := phaseZRollback(t, app)
	db := dao.DB()
	phaseZExec(t, db, `INSERT INTO samples (id, owner, sample_id, created) VALUES
		('smpz00000000001', 'userA', '250611/3', '2025-06-11 10:00:00.000Z'),
		('smpz00000000002', 'userA', '250611/3', '2025-06-11 11:00:00.000Z'),
		('smpz00000000003', 'userB', '250611/3', '2025-06-11 12:00:00.000Z'),
		('smpz00000000004', 'userA', '', '2025-06-11 12:00:00.000Z'),
		('smpz00000000005', 'userA', '', '2025-06-11 13:00:00.000Z')`, nil)
	if err := phaseZUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}
	get := func(id string) (string, string) {
		var sid, orig string
		if err := db.NewQuery(`SELECT sample_id, original_code FROM samples WHERE id={:id}`).
			Bind(dbx.Params{"id": id}).Row(&sid, &orig); err != nil {
			t.Fatal(err)
		}
		return sid, orig
	}
	if sid, orig := get("smpz00000000001"); sid != "250611/3" || orig != "" {
		t.Errorf("first = %q %q", sid, orig)
	}
	if sid, orig := get("smpz00000000002"); sid != "250611/3 (2)" || orig != "250611/3" {
		t.Errorf("second = %q %q", sid, orig)
	}
	if sid, orig := get("smpz00000000003"); sid != "250611/3" || orig != "" {
		t.Errorf("other owner = %q %q", sid, orig)
	}
	for _, id := range []string{"smpz00000000004", "smpz00000000005"} {
		if sid, orig := get(id); sid != "" || orig != "" {
			t.Errorf("%s empty id changed: %q %q", id, sid, orig)
		}
	}
}

func TestPhaseZ_BackfillsCollectingDayAndSource(t *testing.T) {
	app := setupTestApp(t)
	dao := phaseZRollback(t, app)
	db := dao.DB()
	phaseZExec(t, db, `INSERT INTO fieldtrips (id, collecting_day) VALUES ('ftz000000000001', '2025-06-11')`, nil)
	phaseZExec(t, db, `INSERT INTO samples (id, fieldtrip) VALUES ('smpz00000000001', 'ftz000000000001')`, nil)
	if err := phaseZUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}
	var day, src, ftTZ string
	if err := db.NewQuery(`SELECT collecting_day, timezone_source FROM samples WHERE id='smpz00000000001'`).
		Row(&day, &src); err != nil {
		t.Fatal(err)
	}
	if day != "2025-06-11" || src != "device" {
		t.Errorf("got %q %q", day, src)
	}
	if err := db.NewQuery(`SELECT timezone FROM fieldtrips WHERE id='ftz000000000001'`).Row(&ftTZ); err != nil {
		t.Fatal(err)
	}
	if ftTZ != "Europe/Berlin" {
		t.Errorf("fieldtrip timezone = %q", ftTZ)
	}
}

func TestPhaseZ_UserSettingsFields(t *testing.T) {
	app := setupTestApp(t)
	dao := phaseZRollback(t, app)
	db := dao.DB()
	phaseZExec(t, db, `INSERT INTO users (id, email, username, tokenKey, passwordHash, day_cutoff_hour)
		VALUES ('usrz00000000001', 'z@example.com', 'z', 'tk', 'ph', 7)`, nil)
	if err := phaseZUp(db); err != nil {
		t.Fatalf("up: %v", err)
	}
	u, _ := dao.FindCollectionByNameOrId("users")
	for _, n := range []string{"sample_id_format", "sample_id_prefix", "sample_id_offset", "day_cutoff_hour"} {
		if u.Schema.GetFieldByName(n) == nil {
			t.Errorf("users.%s missing", n)
		}
	}
	var h int
	if err := db.NewQuery(`SELECT day_cutoff_hour FROM users WHERE id='usrz00000000001'`).Row(&h); err != nil {
		t.Fatal(err)
	}
	if h != 7 {
		t.Errorf("day_cutoff_hour = %d", h)
	}
}
