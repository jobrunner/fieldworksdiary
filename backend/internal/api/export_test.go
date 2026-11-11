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

	"go.mett.io/fwd-backend/internal/testutil"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func newExportScenario(t *testing.T) (app *tests.TestApp, token string) {
	t.Helper()
	created := testutil.NewTestApp(t)
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

	got := exportAll([]*core.Record{s1, s2})
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
		URL:    "/api/export",
		Headers: map[string]string{
			"Authorization": token,
		},
		ExpectedStatus: http.StatusOK,
		// ZIP-Magic-Bytes "PK" als minimaler Body-Check — der echte
		// Struktur-Check passiert in AfterTestFunc.
		ExpectedContent: []string{"PK"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindExportRoute(e.Router)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, res *http.Response) {
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
		URL:             "/api/export",
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"status":401`},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindExportRoute(e.Router)
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
	owner, _ := app.FindAuthRecordByEmail("users", "alice@example.com")
	samples, _ := app.FindRecordsByFilter("samples", "owner = {:o}", "", 0, 0, dbx.Params{"o": owner.Id})
	pm := makePlacemark(t, app, "DE", "Bayern", "Ochsenfurt")
	samples[0].Set("placemark", pm.Id)
	if err := app.SaveNoValidate(samples[0]); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	fcoll, _ := app.FindCollectionByNameOrId("sample_features")
	feat := core.NewRecord(fcoll)
	feat.Set("owner", owner.Id)
	feat.Set("sample", samples[0].Id)
	feat.Set("source_id", "tk25-blattschnitt-de")
	if err := app.SaveNoValidate(feat); err != nil {
		t.Fatalf("save feature: %v", err)
	}
	// Fremdes Feature darf nicht auftauchen.
	thief, _ := app.FindAuthRecordByEmail("users", "bob@example.com")
	thiefSamples, _ := app.FindRecordsByFilter("samples", "owner = {:o}", "", 0, 0, dbx.Params{"o": thief.Id})
	other := core.NewRecord(fcoll)
	other.Set("owner", thief.Id)
	other.Set("sample", thiefSamples[0].Id)
	other.Set("source_id", "foreign-source")
	if err := app.SaveNoValidate(other); err != nil {
		t.Fatalf("save foreign feature: %v", err)
	}
	app.ResetEventCalls()

	var captured []byte
	scenario := tests.ApiScenario{
		Name:            "export features",
		Method:          http.MethodGet,
		URL:             "/api/export",
		Headers:         map[string]string{"Authorization": token},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{"PK"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindExportRoute(e.Router)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, res *http.Response) {
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

func TestExport_PlacemarksRespectOwnership(t *testing.T) {
	app, token := newExportScenario(t)
	alice, _ := app.FindAuthRecordByEmail("users", "alice@example.com")
	bob, _ := app.FindAuthRecordByEmail("users", "bob@example.com")
	samples, _ := app.FindRecordsByFilter("samples", "owner = {:o}", "", 0, 0, dbx.Params{"o": alice.Id})
	shared := makePlacemark(t, app, "DE", "Bayern", "Ochsenfurt")
	foreign := makePlacemark(t, app, "DE", "Hessen", "Fulda")
	foreign.Set("owner", bob.Id)
	if err := app.SaveNoValidate(foreign); err != nil {
		t.Fatalf("save foreign placemark: %v", err)
	}
	samples[0].Set("placemark", shared.Id)
	samples[0].Set("placemark_suggestion", foreign.Id)
	if err := app.SaveNoValidate(samples[0]); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	// Ownerless manual row (owner cleared by an account deletion): not
	// shared, must not be exported either.
	orphan := makePlacemark(t, app, "DE", "Hessen", "Waise")
	orphan.Set("geocoding_source", "manual")
	if err := app.SaveNoValidate(orphan); err != nil {
		t.Fatalf("save orphan placemark: %v", err)
	}
	samples[1].Set("placemark", orphan.Id)
	if err := app.SaveNoValidate(samples[1]); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	app.ResetEventCalls()

	var captured []byte
	scenario := tests.ApiScenario{
		Name:            "export placemark ownership",
		Method:          http.MethodGet,
		URL:             "/api/export",
		Headers:         map[string]string{"Authorization": token},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{"PK"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindExportRoute(e.Router)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, res *http.Response) {
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
	var pms []map[string]any
	if err := json.Unmarshal(raw["placemarks"], &pms); err != nil {
		t.Fatalf("placemarks: %v", err)
	}
	if len(pms) != 1 || pms[0]["id"] != shared.Id {
		t.Errorf("placemarks = %v, want only the shared one (foreign manual placemark must be absent)", pms)
	}
}
