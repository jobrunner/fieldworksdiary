package migrations

import (
	"strings"
	"testing"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

func TestPlacemarksOrtusMigration_Schema(t *testing.T) {
	app := setupTestApp(t)
	pm, err := app.Dao().FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatalf("find placemarks: %v", err)
	}
	want := []string{"country_iso", "island", "mountain_range", "mountain", "owner"}
	for _, tier := range adminlabels.Tiers {
		s := string(tier)
		want = append(want, s, s+"_level", s+"_native")
	}
	for _, name := range want {
		if pm.Schema.GetFieldByName(name) == nil {
			t.Errorf("placemarks.%s missing", name)
		}
	}
	for _, idx := range pm.Indexes {
		if strings.Contains(strings.ToUpper(idx), "UNIQUE") {
			t.Errorf("unexpected unique index: %s", idx)
		}
	}
	found := false
	for _, idx := range pm.Indexes {
		if strings.Contains(idx, "idx_placemarks_dedup_source_owner") {
			found = true
		}
	}
	if !found {
		t.Errorf("composite index missing: %v", pm.Indexes)
	}
	if pm.ListRule == nil || !strings.Contains(*pm.ListRule, "owner = ''") {
		t.Errorf("list rule = %v", pm.ListRule)
	}
	if pm.CreateRule != nil || pm.UpdateRule != nil || pm.DeleteRule != nil {
		t.Errorf("write rules must be nil")
	}
}

func TestPlacemarksMigration_RenamesBackendService(t *testing.T) {
	app := setupTestApp(t)
	dao := app.Dao()
	// Revert, seed a legacy row, re-apply the up-step.
	if err := placemarksOrtusDown(dao.DB()); err != nil {
		t.Fatalf("down: %v", err)
	}
	if _, err := dao.DB().NewQuery(
		`INSERT INTO placemarks (id, country, geocoding_source, dedup_hash)
		 VALUES ('legacy00000001', 'DE', 'backend-service', 'h1')`).Execute(); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := placemarksOrtusUp(dao.DB()); err != nil {
		t.Fatalf("up: %v", err)
	}
	var src string
	if err := dao.DB().NewQuery(`SELECT geocoding_source FROM placemarks WHERE id='legacy00000001'`).
		Row(&src); err != nil {
		t.Fatalf("select: %v", err)
	}
	if src != "backend_service" {
		t.Errorf("geocoding_source = %q, want backend_service", src)
	}
}

func TestPlacemarksOrtusMigration_DownRestores(t *testing.T) {
	app := setupTestApp(t)
	dao := app.Dao()
	if err := placemarksOrtusDown(dao.DB()); err != nil {
		t.Fatalf("down: %v", err)
	}
	pm, _ := dao.FindCollectionByNameOrId("placemarks")
	if pm.Schema.GetFieldByName("country_iso") != nil {
		t.Errorf("country_iso still present after down")
	}
	if pm.Schema.GetFieldByName("administrative_area") == nil {
		t.Errorf("legacy column lost")
	}
}
