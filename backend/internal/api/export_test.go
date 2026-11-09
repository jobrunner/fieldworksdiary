package api

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// mountExportRoute spiegelt RegisterExportRoute fürs Test-Setup
// (apis.InitApi triggert OnBeforeServe nicht).
func mountExportRoute(app core.App, e *echo.Echo) {
	requireAuth := apis.RequireRecordAuth("users")
	e.GET("/api/export", func(c echo.Context) error {
		return handleExport(app, c)
	}, requireAuth)
}

func newExportScenario(t *testing.T) (app *tests.TestApp, token string) {
	t.Helper()
	created, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	app = created
	owner := makeUser(t, app, "alice@example.com")
	exc := makeFieldtrip(t, app, owner.Id)
	_ = makeSample(t, app, owner.Id, "260519/1", exc.Id)
	_ = makeSample(t, app, owner.Id, "260519/2", exc.Id)

	// Ein zweiter User mit eigenem Sample — darf NICHT im Export
	// von alice auftauchen (Owner-Scoping).
	thief := makeUser(t, app, "bob@example.com")
	thiefFt := makeFieldtrip(t, app, thief.Id)
	_ = makeSample(t, app, thief.Id, "260519/9", thiefFt.Id)

	token = authTokenFor(t, app, owner)
	app.ResetEventCalls()
	return app, token
}

// ────────────────────────────────────────────────────────────────────
// Pure-Function-Tests
// ────────────────────────────────────────────────────────────────────

func TestExportAll_EmptyInputReturnsEmptySlice(t *testing.T) {
	out := exportAll(nil)
	if out == nil {
		t.Fatal("got nil, want empty non-nil slice")
	}
	if len(out) != 0 {
		t.Errorf("len = %d, want 0", len(out))
	}
}

func TestExportAll_PreservesOrder(t *testing.T) {
	app, _ := newExportScenario(t)
	owner := makeUser(t, app, "carl@example.com")
	exc := makeFieldtrip(t, app, owner.Id)
	s1 := makeSample(t, app, owner.Id, "260519/3", exc.Id)
	s2 := makeSample(t, app, owner.Id, "260519/4", exc.Id)

	got := exportAll([]*models.Record{s1, s2})
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0]["id"] != s1.Id || got[1]["id"] != s2.Id {
		t.Errorf("order broken: got [%v, %v]", got[0]["id"], got[1]["id"])
	}
}

// ────────────────────────────────────────────────────────────────────
// HTTP-Integration
// ────────────────────────────────────────────────────────────────────

func TestExport_HappyPath_Returns200_ZIP(t *testing.T) {
	app, token := newExportScenario(t)

	var capturedBody []byte
	scenario := tests.ApiScenario{
		Name:   "export happy",
		Method: http.MethodGet,
		Url:    "/api/export",
		RequestHeaders: map[string]string{
			"Authorization": token,
		},
		ExpectedStatus: http.StatusOK,
		// ZIP-Magic-Bytes "PK" als minimaler Body-Check — der echte
		// Struktur-Check passiert in AfterTestFunc.
		ExpectedContent: []string{"PK"},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountExportRoute(app, e)
		},
		AfterTestFunc: func(t *testing.T, _ *tests.TestApp, res *http.Response) {
			t.Helper()
			if got := res.Header.Get("Content-Type"); got != "application/zip" {
				t.Errorf("Content-Type = %q, want application/zip", got)
			}
			body, _ := io.ReadAll(res.Body)
			capturedBody = body
			if len(body) < 2 || body[0] != 'P' || body[1] != 'K' {
				t.Errorf("body does not start with ZIP magic 'PK': first bytes = %v", body[:min(4, len(body))])
			}
		},
	}
	scenario.Test(t)

	// Inhalt des Archivs prüfen — data.json muss alice's Samples haben
	// und KEIN Sample vom thief.
	if len(capturedBody) == 0 {
		t.Skip("body not captured")
	}
	r, err := zip.NewReader(bytes.NewReader(capturedBody), int64(len(capturedBody)))
	if err != nil {
		t.Fatalf("zip parse: %v", err)
	}
	var dataJSON []byte
	for _, f := range r.File {
		if f.Name == "data.json" {
			rc, _ := f.Open()
			dataJSON, _ = io.ReadAll(rc)
			rc.Close()
			break
		}
	}
	if len(dataJSON) == 0 {
		t.Fatal("data.json missing from ZIP")
	}
	var payload map[string]any
	if err := json.Unmarshal(dataJSON, &payload); err != nil {
		t.Fatalf("data.json parse: %v", err)
	}
	samples, _ := payload["samples"].([]any)
	if len(samples) != 2 {
		t.Errorf("samples count = %d, want 2 (Owner-Scoping)", len(samples))
	}
	// Sicherheits-Check: kein thief-Code im Export.
	body := string(dataJSON)
	if strings.Contains(body, "260519/9") {
		t.Error("Export contains thief's sample code — Owner-Scoping kaputt")
	}
}

func TestExport_NoAuth_Returns401(t *testing.T) {
	app, _ := newExportScenario(t)
	scenario := tests.ApiScenario{
		Name:            "export no auth",
		Method:          http.MethodGet,
		Url:             "/api/export",
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"code":401`},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountExportRoute(app, e)
		},
	}
	scenario.Test(t)
}

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

// _ silences "imported and not used" if a test rev removes the only
// httptest reference.
var _ = httptest.NewRequest

func TestExport_IncludesFeaturesAndPlacemarks(t *testing.T) {
	app, token := newExportScenario(t)
	owner, _ := app.Dao().FindAuthRecordByEmail("users", "alice@example.com")
	samples, _ := app.Dao().FindRecordsByFilter("samples", "owner = {:o}", "", 0, 0, dbx.Params{"o": owner.Id})
	pm := makePlacemark(t, app, "DE", "Bayern", "Ochsenfurt")
	samples[0].Set("placemark", pm.Id)
	if err := app.Dao().SaveRecord(samples[0]); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	fcoll, _ := app.Dao().FindCollectionByNameOrId("sample_features")
	feat := models.NewRecord(fcoll)
	feat.Set("owner", owner.Id)
	feat.Set("sample", samples[0].Id)
	feat.Set("source_id", "tk25-blattschnitt-de")
	if err := app.Dao().SaveRecord(feat); err != nil {
		t.Fatalf("save feature: %v", err)
	}
	// Fremdes Feature darf nicht auftauchen.
	thief, _ := app.Dao().FindAuthRecordByEmail("users", "bob@example.com")
	thiefSamples, _ := app.Dao().FindRecordsByFilter("samples", "owner = {:o}", "", 0, 0, dbx.Params{"o": thief.Id})
	other := models.NewRecord(fcoll)
	other.Set("owner", thief.Id)
	other.Set("sample", thiefSamples[0].Id)
	other.Set("source_id", "foreign-source")
	if err := app.Dao().SaveRecord(other); err != nil {
		t.Fatalf("save foreign feature: %v", err)
	}
	app.ResetEventCalls()

	var captured []byte
	scenario := tests.ApiScenario{
		Name:            "export features",
		Method:          http.MethodGet,
		Url:             "/api/export",
		RequestHeaders:  map[string]string{"Authorization": token},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{"PK"},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountExportRoute(app, e)
		},
		AfterTestFunc: func(t *testing.T, _ *tests.TestApp, res *http.Response) {
			captured, _ = io.ReadAll(res.Body)
		},
	}
	scenario.Test(t)

	r, err := zip.NewReader(bytes.NewReader(captured), int64(len(captured)))
	if err != nil {
		t.Fatalf("zip parse: %v", err)
	}
	var dataJSON []byte
	for _, f := range r.File {
		if f.Name == "data.json" {
			rc, _ := f.Open()
			dataJSON, _ = io.ReadAll(rc)
			rc.Close()
		}
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(dataJSON, &raw); err != nil {
		t.Fatalf("data.json parse: %v", err)
	}
	payload := map[string][]map[string]any{}
	for _, k := range []string{"placemarks", "sample_features"} {
		var arr []map[string]any
		if err := json.Unmarshal(raw[k], &arr); err != nil {
			t.Fatalf("data.json %s: %v", k, err)
		}
		payload[k] = arr
	}
	if len(payload["placemarks"]) != 1 || payload["placemarks"][0]["id"] != pm.Id {
		t.Errorf("placemarks = %v, want exactly the referenced one", payload["placemarks"])
	}
	if len(payload["sample_features"]) != 1 || payload["sample_features"][0]["source_id"] != "tk25-blattschnitt-de" {
		t.Errorf("sample_features = %v, want exactly the owner's one", payload["sample_features"])
	}
}
