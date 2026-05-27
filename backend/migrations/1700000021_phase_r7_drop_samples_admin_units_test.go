package migrations

import "testing"

// The migration runs automatically on tests.NewTestApp(), so by the
// time we get the app the column should already be gone.
func TestDropSamplesAdminUnits_ColumnRemoved(t *testing.T) {
	app := setupTestApp(t)

	samples, err := app.Dao().FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatalf("find samples collection: %v", err)
	}
	if f := samples.Schema.GetFieldByName("admin_units"); f != nil {
		t.Errorf("samples.admin_units still present after R7.4 migration")
	}
}

// fieldtrips keeps its admin_units snapshot (NEW-2) — make sure R7.4
// didn't touch the wrong collection.
func TestDropSamplesAdminUnits_FieldtripUntouched(t *testing.T) {
	app := setupTestApp(t)

	fieldtrips, err := app.Dao().FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		t.Fatalf("find fieldtrips collection: %v", err)
	}
	if f := fieldtrips.Schema.GetFieldByName("admin_units"); f == nil {
		t.Errorf("fieldtrips.admin_units was dropped — NEW-2 says it must stay")
	}
}
