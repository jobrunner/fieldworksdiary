package hooks

import (
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// savedBackendServiceSample stores a sample enriched by the backend
// (status backend_service, shared placemark) and returns it freshly
// loaded, as the update request hook would see it.
func savedBackendServiceSample(t *testing.T, app *tests.TestApp) (*models.Record, *models.Record) {
	t.Helper()
	owner := createTestUser(t, app, "loc"+uniqueSuffix(t)+"@example.com")
	pm := makePlacemarkRow(t, app, "", "backend_service", "h-loc")
	rec := newSampleRecord(t, app)
	rec.Set("owner", owner.Id)
	rec.Set("sample_id", "260519/1")
	rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))
	rec.Set("location_status", "backend_service")
	rec.Set("placemark", pm.Id)
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	fresh, err := app.Dao().FindRecordById("samples", rec.Id)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	return fresh, pm
}

func TestResetStaleLocationStatus_CoordMoveWithoutNewPlaceGoesPending(t *testing.T) {
	app := setupTestApp(t)
	rec, _ := savedBackendServiceSample(t, app)
	rec.Set("latitude", rec.GetFloat("latitude")+0.01)

	resetStaleLocationStatus(rec)

	if got := rec.GetString("location_status"); got != "pending" {
		t.Errorf("location_status = %q, want pending", got)
	}
}

func TestResetStaleLocationStatus_ClientReResolvedKeepsStatus(t *testing.T) {
	app := setupTestApp(t)
	rec, _ := savedBackendServiceSample(t, app)
	other := makePlacemarkRow(t, app, "", "backend_service", "h-other")
	rec.Set("longitude", rec.GetFloat("longitude")+0.01)
	rec.Set("placemark", other.Id)

	resetStaleLocationStatus(rec)

	if got := rec.GetString("location_status"); got != "backend_service" {
		t.Errorf("location_status = %q, want backend_service (client re-resolved)", got)
	}
}

func TestResetStaleLocationStatus_LeavesOtherCasesAlone(t *testing.T) {
	app := setupTestApp(t)

	t.Run("no coordinate change", func(t *testing.T) {
		rec, _ := savedBackendServiceSample(t, app)
		rec.Set("latitude", rec.GetFloat("latitude")+1e-9)
		rec.Set("notes", "edited")
		resetStaleLocationStatus(rec)
		if got := rec.GetString("location_status"); got != "backend_service" {
			t.Errorf("location_status = %q, want backend_service", got)
		}
	})
	t.Run("client sets a status itself", func(t *testing.T) {
		rec, _ := savedBackendServiceSample(t, app)
		rec.Set("latitude", rec.GetFloat("latitude")+0.01)
		rec.Set("location_status", "manual")
		resetStaleLocationStatus(rec)
		if got := rec.GetString("location_status"); got != "manual" {
			t.Errorf("location_status = %q, want manual", got)
		}
	})
}
