package hooks

import (
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// savedBackendServiceSample stores a sample enriched by the backend
// (status backend_service, shared placemark) and returns it freshly
// loaded, as the update request hook would see it.
func savedBackendServiceSample(t *testing.T, app *tests.TestApp) (*core.Record, *core.Record) {
	t.Helper()
	owner := createTestUser(t, app, "loc"+uniqueSuffix(t)+"@example.com")
	pm := makePlacemarkRow(t, app, "", "backend_service", "h-loc")
	rec := newSampleRecord(t, app)
	rec.Set("owner", owner.Id)
	rec.Set("sample_id", "260519/1")
	rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))
	rec.Set("location_status", "backend_service")
	rec.Set("placemark", pm.Id)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	fresh, err := app.FindRecordById("samples", rec.Id)
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

// demSample is savedBackendServiceSample with a DEM height.
func demSample(t *testing.T, app *tests.TestApp) (*core.Record, *core.Record) {
	t.Helper()
	rec, pm := savedBackendServiceSample(t, app)
	rec.Set("elevation", 236)
	rec.Set("elevation_source", "backend_service")
	rec.Set("vertical_accuracy", 5)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatal(err)
	}
	fresh, err := app.FindRecordById("samples", rec.Id)
	if err != nil {
		t.Fatal(err)
	}
	return fresh, pm
}

// A DEM height was read for the old coordinate. After a move it is
// removed, so nothing (Tempus) works with the height of another place;
// the Ortus run writes the new one.
func TestResetStaleLocationStatus_CoordMoveRemovesDEMHeight(t *testing.T) {
	app := setupTestApp(t)
	rec, _ := demSample(t, app)
	rec.Set("latitude", rec.GetFloat("latitude")+0.01)

	resetStaleLocationStatus(rec)

	if rec.GetString("elevation_source") != "" || rec.GetFloat("elevation") != 0 || rec.GetFloat("vertical_accuracy") != 0 {
		t.Errorf("elevation %v (%q), accuracy %v after the move", rec.GetFloat("elevation"),
			rec.GetString("elevation_source"), rec.GetFloat("vertical_accuracy"))
	}
}

func TestResetStaleLocationStatus_DEMHeightStaysWhen(t *testing.T) {
	app := setupTestApp(t)
	t.Run("nothing moved", func(t *testing.T) {
		rec, _ := demSample(t, app)
		rec.Set("notes", "x")
		resetStaleLocationStatus(rec)
		if rec.GetString("elevation_source") != "backend_service" {
			t.Error("height removed without a move")
		}
	})
	t.Run("the client sent a new height", func(t *testing.T) {
		rec, _ := demSample(t, app)
		rec.Set("latitude", rec.GetFloat("latitude")+0.01)
		rec.Set("elevation", 301)
		resetStaleLocationStatus(rec)
		if rec.GetFloat("elevation") != 301 {
			t.Error("the client's new height was removed")
		}
	})
	t.Run("the client resolved the place itself", func(t *testing.T) {
		// Status stays backend_service: no Ortus run would write a new
		// height, so the one there stays.
		rec, _ := demSample(t, app)
		other := makePlacemarkRow(t, app, "", "backend_service", "h-loc2")
		rec.Set("latitude", rec.GetFloat("latitude")+0.01)
		rec.Set("placemark", other.Id)
		resetStaleLocationStatus(rec)
		if rec.GetString("elevation_source") != "backend_service" {
			t.Error("height removed although no Ortus run follows")
		}
	})
	t.Run("gps height", func(t *testing.T) {
		rec, _ := demSample(t, app)
		rec.Set("elevation_source", "location_service")
		if err := app.SaveNoValidate(rec); err != nil {
			t.Fatal(err)
		}
		rec, err := app.FindRecordById("samples", rec.Id)
		if err != nil {
			t.Fatal(err)
		}
		rec.Set("latitude", rec.GetFloat("latitude")+0.01)
		resetStaleLocationStatus(rec)
		if rec.GetString("elevation_source") != "location_service" || rec.GetFloat("elevation") != 236 {
			t.Error("a GPS height is the user's own and stays")
		}
	})
}
