package migrations

import "testing"

func TestSamplesOrtusMigration_Schema(t *testing.T) {
	app := setupTestApp(t)
	s, err := app.Dao().FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatalf("find samples: %v", err)
	}
	if s.Schema.GetFieldByName("altitude") != nil {
		t.Errorf("altitude still present")
	}
	for _, name := range []string{
		"elevation", "elevation_source", "location_status", "placemark",
		"placemark_suggestion", "mtb_sheet_number", "mtb_sheet_name",
		"mtb_quadrant",
		"slope_deg", "aspect_deg", "bearing_distance_km", "aspect_compass",
		"bearing_label", "bearing_reference", "bearing_compass",
		"terrain_flat", "bearing_inside",
	} {
		if s.Schema.GetFieldByName(name) == nil {
			t.Errorf("samples.%s missing", name)
		}
	}
}

func TestSamplesMigration_AltitudeBecomesElevation(t *testing.T) {
	app := setupTestApp(t)
	dao := app.Dao()
	if err := samplesOrtusDown(dao.DB()); err != nil {
		t.Fatalf("down: %v", err)
	}
	s, _ := dao.FindCollectionByNameOrId("samples")
	if s.Schema.GetFieldByName("altitude") == nil || s.Schema.GetFieldByName("elevation") != nil {
		t.Fatalf("down did not restore altitude")
	}
	if _, err := dao.DB().NewQuery(
		`INSERT INTO samples (id, altitude) VALUES ('smp000000000001', 312.5), ('smp000000000002', 0)`).Execute(); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := samplesOrtusUp(dao.DB()); err != nil {
		t.Fatalf("up: %v", err)
	}
	var elev float64
	var src, status string
	if err := dao.DB().NewQuery(`SELECT elevation, elevation_source, location_status FROM samples WHERE id='smp000000000001'`).
		Row(&elev, &src, &status); err != nil {
		t.Fatalf("select: %v", err)
	}
	if elev != 312.5 || src != "location_service" || status != "pending" {
		t.Errorf("got %v %q %q", elev, src, status)
	}
	if err := dao.DB().NewQuery(`SELECT elevation_source, location_status FROM samples WHERE id='smp000000000002'`).
		Row(&src, &status); err != nil {
		t.Fatalf("select2: %v", err)
	}
	if src != "" || status != "pending" {
		t.Errorf("zero row: %q %q", src, status)
	}
}
