package geoplace_test

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// After migration 1700000027 the legacy columns are gone; the mapping
// must be a no-op instead of failing on the unknown filter fields.
func TestMapLegacyManualPlacemarks_NoopWithoutLegacyColumns(t *testing.T) {
	app := newStoreApp(t)
	n, err := geoplace.MapLegacyManualPlacemarks(app.Dao(), nil)
	if err != nil || n != 0 {
		t.Fatalf("got (%d, %v), want (0, nil)", n, err)
	}
}

// addLegacyColumns re-adds the pre-Ortus placemark columns that
// migration 1700000027 dropped.
func addLegacyColumns(t *testing.T, app *tests.TestApp) {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range geoplace.LegacyPlacemarkFields {
		if coll.Schema.GetFieldByName(n) == nil {
			coll.Schema.AddField(&schema.SchemaField{Name: n, Type: schema.FieldTypeText})
		}
	}
	if err := app.Dao().SaveCollection(coll); err != nil {
		t.Fatal(err)
	}
}

func TestMapLegacyManualPlacemarks_OwnersClonesAndLog(t *testing.T) {
	app := newStoreApp(t)
	addLegacyColumns(t, app)
	dao := app.Dao()
	a := mkUser(t, app, "aleg1@example.com")
	b := mkUser(t, app, "bleg2@example.com")

	pmColl, _ := dao.FindCollectionByNameOrId("placemarks")
	pm := models.NewRecord(pmColl)
	for k, v := range map[string]string{
		"country": "DE", "administrative_area": "Bayern", "sub_administrative_area": "Unterfranken",
		"locality": "Würzburg", "sub_locality": "Heidingsfeld", "postal_code": "97084",
		"name": "Hexenbruch", "thoroughfare": "Am Weg", "geocoding_source": "manual", "dedup_hash": "legacy",
	} {
		pm.Set(k, v)
	}
	if err := dao.SaveRecord(pm); err != nil {
		t.Fatal(err)
	}
	locColl, _ := dao.FindCollectionByNameOrId("localities")
	var locs []*models.Record
	for _, u := range []*models.Record{a, b} {
		l := models.NewRecord(locColl)
		l.Set("owner", u.Id)
		l.Set("name", "Ort")
		l.Set("latitude", 49.7)
		l.Set("longitude", 9.9)
		l.Set("placemark", pm.Id)
		l.Set("version", 1)
		if err := dao.SaveRecord(l); err != nil {
			t.Fatal(err)
		}
		locs = append(locs, l)
	}

	var buf bytes.Buffer
	n, err := geoplace.MapLegacyManualPlacemarks(dao, slog.New(slog.NewJSONHandler(&buf, nil)))
	if err != nil || n != 1 {
		t.Fatalf("got (%d, %v), want (1, nil)", n, err)
	}

	got, _ := dao.FindRecordById("placemarks", pm.Id)
	if got.GetString("owner") != a.Id || got.GetString("country_iso") != "DE" ||
		got.GetString("admin_state") != "Bayern" || got.GetString("admin_county") != "Unterfranken" ||
		got.GetString("admin_municipality") != "Würzburg" || got.GetString("admin_submunicipality") != "Heidingsfeld" ||
		got.GetString("geocoding_source") != "manual" {
		t.Errorf("original placemark not mapped: %v", got.PublicExport())
	}
	if got.GetString("dedup_hash") != geoplace.PlaceFromRecord(got).DedupHash() {
		t.Error("dedup_hash not recomputed")
	}
	locB, _ := dao.FindRecordById("localities", locs[1].Id)
	clone, err := dao.FindRecordById("placemarks", locB.GetString("placemark"))
	if err != nil || clone.Id == pm.Id || clone.GetString("owner") != b.Id ||
		clone.GetString("admin_municipality") != "Würzburg" || locB.GetInt("version") != 2 {
		t.Errorf("owner B clone missing or wrong: err=%v", err)
	}
	for _, want := range []string{`"old_postal_code":"97084"`, `"old_name":"Hexenbruch"`,
		`"old_thoroughfare":"Am Weg"`, `"new_admin_municipality":"Würzburg"`} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("log lacks %s: %s", want, buf.String())
		}
	}

	// Idempotent: the mapped row has a country_iso now.
	if n, err := geoplace.MapLegacyManualPlacemarks(dao, nil); err != nil || n != 0 {
		t.Errorf("second run = (%d, %v), want (0, nil)", n, err)
	}
}
