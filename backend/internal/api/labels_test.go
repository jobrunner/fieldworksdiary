package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/testutil"

	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// setupTestApp baut eine frische PB-Test-App und registriert unsere
// Label-Routes über das OnBeforeServe-Hook-Pendant für Tests:
// `apis.InitApi` löst die Routes ein.
func setupTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app := testutil.NewTestApp(t)
	return app
}

// makeUser legt einen verifizierten User in `users` an.
func makeUser(t *testing.T, app *tests.TestApp, email string) *core.Record {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	rec := core.NewRecord(coll)
	rec.SetEmail(email)
	username := strings.SplitN(email, "@", 2)[0] + "_" + strings.ReplaceAll(t.Name(), "/", "_")
	rec.Set("username", username)
	rec.SetPassword("test1234password")
	rec.SetVerified(true)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return rec
}

// authTokenFor erzeugt einen JWT für den User. Wird im Authorization-
// Header eingesetzt.
func authTokenFor(t *testing.T, app *tests.TestApp, user *core.Record) string {
	t.Helper()
	tok, err := user.NewAuthToken()
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	return tok
}

// makeSample legt ein Sample an, das dem User gehört. Pflichtfelder
// sind code (eindeutig), lat, lon, fieldtrip (Relation).
func makeSample(t *testing.T, app *tests.TestApp, ownerID, code, fieldtripID string) *core.Record {
	t.Helper()
	coll, _ := app.FindCollectionByNameOrId("samples")
	rec := core.NewRecord(coll)
	rec.Set("owner", ownerID)
	rec.Set("sample_id", code)
	rec.Set("latitude", 49.793)
	rec.Set("longitude", 9.939)
	rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	rec.Set("fieldtrip", fieldtripID)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	return rec
}

func makeFieldtrip(t *testing.T, app *tests.TestApp, ownerID string) *core.Record {
	t.Helper()
	coll, _ := app.FindCollectionByNameOrId("fieldtrips")
	rec := core.NewRecord(coll)
	rec.Set("owner", ownerID)
	rec.Set("collecting_day", "2026-05-19")
	rec.Set("title", "Test")
	rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	rec.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save fieldtrip: %v", err)
	}
	return rec
}

// ────────────────────────────────────────────────────────────────────
// Pure-Function-Tests — schnell, isoliert
// ────────────────────────────────────────────────────────────────────

func TestAssertOwnerOnSamples_PassesWhenAllMatch(t *testing.T) {
	app := setupTestApp(t)
	owner := makeUser(t, app, "owner@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	s1 := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	s2 := makeSample(t, app, owner.Id, "260519/2", ft.Id)

	err := assertOwnerOnSamples([]*core.Record{s1, s2}, owner.Id)
	if err != nil {
		t.Errorf("expected pass, got %v", err)
	}
}

func TestAssertOwnerOnSamples_FailsOnMixedOwners(t *testing.T) {
	app := setupTestApp(t)
	owner := makeUser(t, app, "owner@example.com")
	thief := makeUser(t, app, "thief@example.com")
	ft1 := makeFieldtrip(t, app, owner.Id)
	ft2 := makeFieldtrip(t, app, thief.Id)
	mine := makeSample(t, app, owner.Id, "260519/1", ft1.Id)
	theirs := makeSample(t, app, thief.Id, "260519/1", ft2.Id)

	err := assertOwnerOnSamples([]*core.Record{mine, theirs}, owner.Id)
	if err == nil {
		t.Fatal("expected 403, got nil")
	}
}

func TestReadLabelRequest_RejectsEmptySampleIDs(t *testing.T) {
	c := requestEventWithJSON(t, []byte(`{"sample_ids":[]}`))
	_, err := readLabelRequest(c)
	if err == nil {
		t.Fatal("expected 400 for empty sample_ids")
	}
}

func TestReadLabelRequest_DefaultsTemplate(t *testing.T) {
	c := requestEventWithJSON(t, []byte(`{"sample_ids":["a","b"]}`))
	req, err := readLabelRequest(c)
	if err != nil {
		t.Fatalf("readLabelRequest: %v", err)
	}
	if req.Template != "default" {
		t.Errorf("template = %q, want 'default'", req.Template)
	}
}

func TestReadLabelRequest_RejectsMalformedJSON(t *testing.T) {
	c := requestEventWithJSON(t, []byte(`{not-json`))
	_, err := readLabelRequest(c)
	if err == nil {
		t.Fatal("expected 400 for malformed JSON")
	}
}

func TestDeterminationToLabel_FallsBackToFullName(t *testing.T) {
	app := setupTestApp(t)
	owner := makeUser(t, app, "u@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)

	personColl, _ := app.FindCollectionByNameOrId("people")
	person := core.NewRecord(personColl)
	person.Set("owner", owner.Id)
	person.Set("full_name", "Carl von Linné")
	// abbreviation explicit empty → fallback expected
	if err := app.SaveNoValidate(person); err != nil {
		t.Fatalf("save person: %v", err)
	}

	detColl, _ := app.FindCollectionByNameOrId("determinations")
	det := core.NewRecord(detColl)
	det.Set("owner", owner.Id)
	det.Set("sample", sample.Id)
	det.Set("species_text", "Carabus auratus")
	det.Set("kind", "det")
	det.Set("person", person.Id)
	det.Set("determined_on", time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC))
	if err := app.SaveNoValidate(det); err != nil {
		t.Fatalf("save det: %v", err)
	}

	label := determinationToLabel(sample, det, map[string]*core.Record{person.Id: person})
	if label.PersonAbbrev != "Carl von Linné" {
		t.Errorf("PersonAbbrev = %q, want full_name fallback", label.PersonAbbrev)
	}
	if label.SpeciesText != "Carabus auratus" {
		t.Errorf("SpeciesText = %q, want 'Carabus auratus'", label.SpeciesText)
	}
	if label.Kind != "det" {
		t.Errorf("Kind = %q, want 'det'", label.Kind)
	}
}

func TestSampleToLabel_UsesPlacemark(t *testing.T) {
	app := setupTestApp(t)
	owner := makeUser(t, app, "label@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	pm := makePlacemark(t, app, "DE", "Bayern", "Ochsenfurt")
	sample.Set("placemark", pm.Id)
	sample.Set("mtb_sheet_number", "6425")
	if err := app.SaveNoValidate(sample); err != nil {
		t.Fatalf("save sample: %v", err)
	}

	label := sampleToLabel(sample, ft, pm)
	if label.Country != "DE" || label.AdminArea != "Bayern" || label.Locality != "Ochsenfurt" {
		t.Errorf("admin = %q/%q/%q, want DE/Bayern/Ochsenfurt", label.Country, label.AdminArea, label.Locality)
	}
	if label.MTBSheetNumber != "" || label.MTBSheetName != "" {
		t.Errorf("MTB must stay empty, got %q/%q", label.MTBSheetNumber, label.MTBSheetName)
	}

	bare := makeSample(t, app, owner.Id, "260519/2", ft.Id)
	l2 := sampleToLabel(bare, ft, nil)
	if l2.Country != "" || l2.AdminArea != "" || l2.Locality != "" {
		t.Errorf("sample without placemark should have empty admin fields, got %+v", l2)
	}
}

func makePlacemark(t *testing.T, app *tests.TestApp, country, state, municipality string) *core.Record {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatalf("placemarks collection: %v", err)
	}
	rec := core.NewRecord(coll)
	rec.Set("country_iso", country)
	rec.Set("admin_country", country)
	rec.Set("admin_state", state)
	rec.Set("admin_municipality", municipality)
	rec.Set("geocoding_source", "backend_service")
	rec.Set("dedup_hash", country+"|"+state+"|"+municipality)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save placemark: %v", err)
	}
	return rec
}

// ────────────────────────────────────────────────────────────────────
// HTTP-Integration via ApiScenario
// ────────────────────────────────────────────────────────────────────

// scenario factory: ApiScenario ruft `defer app.Cleanup()` selbst auf.
// Wir dürfen hier KEIN t.Cleanup hinzufügen, sonst doppelter Cleanup-
// Pfad → Log-Channel-Hang. Deshalb eine separate Helper-Funktion.
func newLabelsScenario(t *testing.T) (app *tests.TestApp, token string, sampleID string, otherSampleID string) {
	t.Helper()
	created := testutil.NewTestApp(t)
	app = created
	owner := makeUser(t, app, "owner@example.com")
	other := makeUser(t, app, "other@example.com")
	ftOwner := makeFieldtrip(t, app, owner.Id)
	ftOther := makeFieldtrip(t, app, other.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ftOwner.Id)
	otherSample := makeSample(t, app, other.Id, "260519/1", ftOther.Id)

	token = authTokenFor(t, app, owner)
	// Setup-Side-Effects bei den Event-Countern wegputzen, damit der
	// ApiScenario-Check nur unsere echten Test-Aktionen sieht.
	app.ResetEventCalls()
	return app, token, sample.Id, otherSample.Id
}

func TestLocalityLabel_HappyPath_Returns200(t *testing.T) {
	app, token, sampleID, _ := newLabelsScenario(t)
	body, _ := json.Marshal(map[string]any{
		"sample_ids": []string{sampleID},
	})
	scenario := tests.ApiScenario{
		Name:   "locality label happy path",
		Method: http.MethodPost,
		URL:    "/api/label-pdfs/locality",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"kind":"locality"`, `"pdf_file"`},
		ExpectedEvents: map[string]int{
			// Speichern des label_pdfs-Records.
			"OnModelCreate":             1,
			"OnModelAfterCreateSuccess": 1,
		},
		TestAppFactory: func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindLabelRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestLocalityLabel_NoAuth_Returns401(t *testing.T) {
	app, _, sampleID, _ := newLabelsScenario(t)
	body, _ := json.Marshal(map[string]any{"sample_ids": []string{sampleID}})
	scenario := tests.ApiScenario{
		Name:            "locality label no auth",
		Method:          http.MethodPost,
		URL:             "/api/label-pdfs/locality",
		Body:            bytes.NewReader(body),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"status":401`},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindLabelRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestLocalityLabel_ForeignSample_Returns403(t *testing.T) {
	app, token, _, otherSampleID := newLabelsScenario(t)
	body, _ := json.Marshal(map[string]any{
		"sample_ids": []string{otherSampleID},
	})
	scenario := tests.ApiScenario{
		Name:   "locality label foreign sample",
		Method: http.MethodPost,
		URL:    "/api/label-pdfs/locality",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusForbidden,
		ExpectedContent: []string{`"status":403`, "does not belong"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindLabelRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestLocalityLabel_EmptySampleIDs_Returns400(t *testing.T) {
	app, token, _, _ := newLabelsScenario(t)
	body := []byte(`{"sample_ids":[]}`)
	scenario := tests.ApiScenario{
		Name:   "locality label empty body",
		Method: http.MethodPost,
		URL:    "/api/label-pdfs/locality",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusBadRequest,
		ExpectedContent: []string{`"status":400`, "Sample_ids"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindLabelRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

func requestEventWithJSON(t *testing.T, body []byte) *core.RequestEvent {
	t.Helper()
	e := &core.RequestEvent{}
	e.Request = httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(body))
	e.Request.Header.Set("Content-Type", "application/json")
	e.Response = httptest.NewRecorder()
	return e
}

func TestBatchLoadPlacemarks_FiltersInvisible(t *testing.T) {
	app := setupTestApp(t)
	alice := makeUser(t, app, "alice@example.com")
	bob := makeUser(t, app, "bob@example.com")
	ft := makeFieldtrip(t, app, alice.Id)
	shared := makePlacemark(t, app, "DE", "Bayern", "Ochsenfurt")
	own := makePlacemark(t, app, "DE", "Bayern", "Eigen")
	own.Set("owner", alice.Id)
	own.Set("geocoding_source", "manual")
	foreign := makePlacemark(t, app, "DE", "Hessen", "Fulda")
	foreign.Set("owner", bob.Id)
	foreign.Set("geocoding_source", "manual")
	orphan := makePlacemark(t, app, "DE", "Hessen", "Waise")
	orphan.Set("geocoding_source", "manual")
	for _, r := range []*core.Record{own, foreign, orphan} {
		if err := app.SaveNoValidate(r); err != nil {
			t.Fatalf("save placemark: %v", err)
		}
	}
	var samples []*core.Record
	for i, pm := range []*core.Record{shared, own, foreign, orphan} {
		s := makeSample(t, app, alice.Id, "260519/"+string(rune('1'+i)), ft.Id)
		s.Set("placemark", pm.Id)
		samples = append(samples, s)
	}
	got, err := batchLoadPlacemarks(app, samples, alice.Id)
	if err != nil {
		t.Fatalf("batchLoadPlacemarks: %v", err)
	}
	if got[shared.Id] == nil || got[own.Id] == nil {
		t.Errorf("visible placemarks missing: %v", got)
	}
	if got[foreign.Id] != nil || got[orphan.Id] != nil {
		t.Errorf("invisible placemarks returned: %v", got)
	}
}
