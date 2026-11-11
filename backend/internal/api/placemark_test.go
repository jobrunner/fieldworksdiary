package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"go.mett.io/fwd-backend/internal/testutil"

	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// newPlacemarkScenario seeds a user + a locality, returns the app,
// the user's token, and the locality id. Locality has lat/lon set
// so the PATCH handler doesn't get confused.
func newPlacemarkScenario(t *testing.T) (app *tests.TestApp, token, localityID, otherLocalityID string) {
	t.Helper()
	created := testutil.NewTestApp(t)
	app = created
	// (No t.Cleanup(app.Cleanup) — newLabelsScenario doesn't do it
	// either, and an extra cleanup races the PB logger-hook
	// shutdown into a multi-minute hang.)

	owner := makeUser(t, app, "pmuser@example.com")
	other := makeUser(t, app, "intruder@example.com")

	mkLoc := func(ownerID string) *core.Record {
		coll, _ := app.FindCollectionByNameOrId("localities")
		rec := core.NewRecord(coll)
		rec.Set("owner", ownerID)
		rec.Set("name", "Test")
		rec.Set("latitude", 49.79)
		rec.Set("longitude", 9.94)
		rec.Set("location_source", "user")
		rec.Set("version", 1)
		if err := app.SaveNoValidate(rec); err != nil {
			t.Fatalf("save locality: %v", err)
		}
		return rec
	}
	loc := mkLoc(owner.Id)
	otherLoc := mkLoc(other.Id)

	token = authTokenFor(t, app, owner)
	// Wipe the event-counter side-effects from the setup writes
	// so the ApiScenario.Expected* checks only see the events the
	// actual test produces.
	app.ResetEventCalls()
	return app, token, loc.Id, otherLoc.Id
}

func TestSetManualPlacemark_HappyPath_AttachesAndReturns200(t *testing.T) {
	app, token, localityID, _ := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{
		"country_iso":       "DE",
		"admin_state":       "Bayern",
		"admin_state_level": 4,
		"island":            "Testinsel",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark happy",
		Method: http.MethodPatch,
		URL:    "/api/localities/" + localityID + "/placemark",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus: http.StatusOK,
		ExpectedContent: []string{
			`"country_iso":"DE"`,
			`"geocoding_source":"manual"`,
			`"island":"Testinsel"`,
		},
		ExpectedEvents: map[string]int{
			// One placemark create + one locality update.
			"OnModelCreate":             1,
			"OnModelAfterCreateSuccess": 1,
			"OnModelUpdate":             1,
			"OnModelAfterUpdateSuccess": 1,
		},
		TestAppFactory: func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkOverrideRoutes(e.Router)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, _ *http.Response) {
			t.Helper()
			loc, err := app.FindRecordById("localities", localityID)
			if err != nil {
				t.Fatalf("locality vanished: %v", err)
			}
			pmID := loc.GetString("placemark")
			if pmID == "" {
				t.Fatal("locality was not pointed at the new placemark")
			}
			pm, _ := app.FindRecordById("placemarks", pmID)
			if pm.GetString("geocoding_source") != "manual" {
				t.Errorf("geocoding_source = %q, want manual", pm.GetString("geocoding_source"))
			}
		},
	}
	scenario.Test(t)
}

func TestSetManualPlacemark_MissingCountry_Returns400(t *testing.T) {
	app, token, localityID, _ := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{
		"island": "Testinsel",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark missing country",
		Method: http.MethodPatch,
		URL:    "/api/localities/" + localityID + "/placemark",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusBadRequest,
		ExpectedContent: []string{"country_iso) must be exactly 2 letters"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkOverrideRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestSetManualPlacemark_ForeignLocality_Returns403(t *testing.T) {
	app, token, _, otherLocalityID := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{
		"country_iso": "DE",
		"island":      "Testinsel",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark foreign locality",
		Method: http.MethodPatch,
		URL:    "/api/localities/" + otherLocalityID + "/placemark",
		Body:   bytes.NewReader(body),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusForbidden,
		ExpectedContent: []string{"does not belong"},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkOverrideRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestSetManualPlacemark_NoAuth_Returns401(t *testing.T) {
	app, _, localityID, _ := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{"country_iso": "DE", "island": "Testinsel"})
	scenario := tests.ApiScenario{
		Name:            "manual placemark no auth",
		Method:          http.MethodPatch,
		URL:             "/api/localities/" + localityID + "/placemark",
		Body:            bytes.NewReader(body),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"status":401`},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkOverrideRoutes(e.Router)
		},
	}
	scenario.Test(t)
}

func TestClearManualPlacemark_DetachesPlacemark(t *testing.T) {
	app, token, localityID, _ := newPlacemarkScenario(t)

	// Seed an attached placemark first.
	pmColl, _ := app.FindCollectionByNameOrId("placemarks")
	pm := core.NewRecord(pmColl)
	pm.Set("country_iso", "DE")
	pm.Set("admin_municipality", "Würzburg")
	pm.Set("geocoding_source", "manual")
	pm.Set("dedup_hash", "deadbeef0000000000000000000000000000000000000000000000000000beef")
	if err := app.SaveNoValidate(pm); err != nil {
		t.Fatalf("seed placemark: %v", err)
	}
	loc, _ := app.FindRecordById("localities", localityID)
	loc.Set("placemark", pm.Id)
	if err := app.SaveNoValidate(loc); err != nil {
		t.Fatalf("attach placemark: %v", err)
	}

	scenario := tests.ApiScenario{
		Name:   "clear manual placemark",
		Method: http.MethodDelete,
		URL:    "/api/localities/" + localityID + "/placemark/override",
		Headers: map[string]string{
			"Authorization": token,
		},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"cleared"`},
		ExpectedEvents: map[string]int{
			// Setup writes are not counted (ApiScenario resets the
			// counters after BeforeTestFunc); the DELETE produces one
			// update on the locality and creates nothing.
			"OnModelCreate":             0,
			"OnModelUpdate":             1,
			"OnModelAfterUpdateSuccess": 1,
		},
		TestAppFactory: func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkOverrideRoutes(e.Router)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, _ *http.Response) {
			t.Helper()
			reloaded, _ := app.FindRecordById("localities", localityID)
			if reloaded.GetString("placemark") != "" {
				t.Errorf("placemark still attached after clear: %q", reloaded.GetString("placemark"))
			}
			// The placemark record itself stays — other localities
			// may still reference it.
			if _, err := app.FindRecordById("placemarks", pm.Id); err != nil {
				t.Errorf("placemark row should NOT be deleted on clear: %v", err)
			}
		},
	}
	scenario.Test(t)
}

func resolveRequest(app *tests.TestApp, token string, body map[string]any, expStatus int, expContent []string, after func(t testing.TB)) tests.ApiScenario {
	raw, _ := json.Marshal(body)
	sc := tests.ApiScenario{
		Name:   "resolve",
		Method: http.MethodPost,
		URL:    "/api/placemarks/resolve",
		Body:   bytes.NewReader(raw),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  expStatus,
		ExpectedContent: expContent,
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindPlacemarkResolveRoute(e.Router)
		},
	}
	if expStatus == http.StatusOK {
		sc.ExpectedEvents = map[string]int{"OnModelCreate": 1, "OnModelAfterCreateSuccess": 1}
	}
	if after != nil {
		sc.AfterTestFunc = func(t testing.TB, _ *tests.TestApp, _ *http.Response) { after(t) }
	}
	return sc
}

func TestResolveEndpoint_ManualSetsOwner(t *testing.T) {
	app, token, _, _ := newPlacemarkScenario(t)
	ownerUser, err := app.FindAuthRecordByEmail("users", "pmuser@example.com")
	if err != nil {
		t.Fatal(err)
	}
	owner := ownerUser.Id
	sc := resolveRequest(app, token, map[string]any{
		"geocoding_source":  "manual",
		"country_iso":       "ES",
		"admin_state":       "Canarias",
		"admin_state_level": 4,
		"island":            "La Palma",
	}, http.StatusOK, []string{`"id":"`, `"geocoding_source":"manual"`, `"island":"La Palma"`}, func(t testing.TB) {
		recs, err := app.FindRecordsByFilter("placemarks", "geocoding_source = 'manual'", "", 0, 0)
		if err != nil || len(recs) != 1 {
			t.Fatalf("manual placemarks = %d, err %v", len(recs), err)
		}
		if recs[0].GetString("owner") != owner {
			t.Errorf("owner = %q, want %q", recs[0].GetString("owner"), owner)
		}
	})
	sc.Test(t)
}

func TestResolveEndpoint_BackendServiceHasNoOwner(t *testing.T) {
	app, token, _, _ := newPlacemarkScenario(t)
	sc := resolveRequest(app, token, map[string]any{
		"geocoding_source": "backend_service",
		"country_iso":      "ES",
		"island":           "La Palma",
	}, http.StatusOK, []string{`"owner":""`}, nil)
	sc.Test(t)
}

// Each ApiScenario tears its app down, so every case gets a fresh one.
func TestResolveEndpoint_BadSource400(t *testing.T) {
	app, token, _, _ := newPlacemarkScenario(t)
	s1 := resolveRequest(app, token, map[string]any{"geocoding_source": "x", "country_iso": "ES"},
		http.StatusBadRequest, []string{"geocoding_source"}, nil)
	s1.Test(t)
}

func TestResolveEndpoint_MissingCountry400(t *testing.T) {
	app, token, _, _ := newPlacemarkScenario(t)
	s2 := resolveRequest(app, token, map[string]any{"geocoding_source": "manual"},
		http.StatusBadRequest, []string{"country_iso) must be exactly 2 letters"}, nil)
	s2.Test(t)
}

func TestResolveEndpoint_InvalidCountryLength400(t *testing.T) {
	app, token, _, _ := newPlacemarkScenario(t)
	sc := resolveRequest(app, token, map[string]any{"geocoding_source": "manual", "country_iso": "DEU"},
		http.StatusBadRequest, []string{"exactly 2 letters"}, nil)
	sc.Test(t)
}
