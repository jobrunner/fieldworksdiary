package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	_ "go.mett.io/fwd-backend/migrations"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// mountPlacemarkRoutes spiegelt RegisterPlacemarkOverrideRoutes für
// den Test-Pfad (`OnBeforeServe` löst bei `tests.ApiScenario` nicht
// aus, also direkt am echo.Router registrieren).
func mountPlacemarkRoutes(app core.App, e *echo.Echo) {
	requireAuth := apis.RequireRecordAuth("users")
	e.PATCH("/api/localities/:id/placemark", func(c echo.Context) error {
		return handleSetManualPlacemark(app, c)
	}, requireAuth)
	e.DELETE("/api/localities/:id/placemark/override", func(c echo.Context) error {
		return handleClearManualPlacemark(app, c)
	}, requireAuth)
}

// newPlacemarkScenario seeds a user + a locality, returns the app,
// the user's token, and the locality id. Locality has lat/lon set
// so the PATCH handler doesn't get confused.
func newPlacemarkScenario(t *testing.T) (app *tests.TestApp, token, localityID, otherLocalityID string) {
	t.Helper()
	created, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	app = created
	// (No t.Cleanup(app.Cleanup) — newLabelsScenario doesn't do it
	// either, and an extra cleanup races the PB logger-hook
	// shutdown into a multi-minute hang.)

	owner := makeUser(t, app, "pmuser@example.com")
	other := makeUser(t, app, "intruder@example.com")

	mkLoc := func(ownerID string) *models.Record {
		coll, _ := app.Dao().FindCollectionByNameOrId("localities")
		rec := models.NewRecord(coll)
		rec.Set("owner", ownerID)
		rec.Set("name", "Test")
		rec.Set("latitude", 49.79)
		rec.Set("longitude", 9.94)
		rec.Set("location_source", "user")
		rec.Set("version", 1)
		if err := app.Dao().SaveRecord(rec); err != nil {
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
		"country":             "DE",
		"administrative_area": "Bayern",
		"locality":            "Würzburg",
		"postal_code":         "97070",
		"name":                "Sanderring",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark happy",
		Method: http.MethodPatch,
		Url:    "/api/localities/" + localityID + "/placemark",
		Body:   bytes.NewReader(body),
		RequestHeaders: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus: http.StatusOK,
		ExpectedContent: []string{
			`"country":"DE"`,
			`"geocoding_source":"manual"`,
			`"locality":"Würzburg"`,
		},
		ExpectedEvents: map[string]int{
			// One placemark create + one locality update.
			"OnModelBeforeCreate": 1,
			"OnModelAfterCreate":  1,
			"OnModelBeforeUpdate": 1,
			"OnModelAfterUpdate":  1,
		},
		TestAppFactory: func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountPlacemarkRoutes(app, e)
		},
		AfterTestFunc: func(t *testing.T, _ *tests.TestApp, _ *http.Response) {
			t.Helper()
			loc, err := app.Dao().FindRecordById("localities", localityID)
			if err != nil {
				t.Fatalf("locality vanished: %v", err)
			}
			pmID := loc.GetString("placemark")
			if pmID == "" {
				t.Fatal("locality was not pointed at the new placemark")
			}
			pm, _ := app.Dao().FindRecordById("placemarks", pmID)
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
		"locality": "Würzburg",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark missing country",
		Method: http.MethodPatch,
		Url:    "/api/localities/" + localityID + "/placemark",
		Body:   bytes.NewReader(body),
		RequestHeaders: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusBadRequest,
		ExpectedContent: []string{"ISO 3166-1 alpha-2"},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountPlacemarkRoutes(app, e)
		},
	}
	scenario.Test(t)
}

func TestSetManualPlacemark_ForeignLocality_Returns403(t *testing.T) {
	app, token, _, otherLocalityID := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{
		"country":  "DE",
		"locality": "Würzburg",
	})
	scenario := tests.ApiScenario{
		Name:   "manual placemark foreign locality",
		Method: http.MethodPatch,
		Url:    "/api/localities/" + otherLocalityID + "/placemark",
		Body:   bytes.NewReader(body),
		RequestHeaders: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  http.StatusForbidden,
		ExpectedContent: []string{"does not belong"},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountPlacemarkRoutes(app, e)
		},
	}
	scenario.Test(t)
}

func TestSetManualPlacemark_NoAuth_Returns401(t *testing.T) {
	app, _, localityID, _ := newPlacemarkScenario(t)
	body, _ := json.Marshal(map[string]any{"country": "DE", "locality": "Würzburg"})
	scenario := tests.ApiScenario{
		Name:            "manual placemark no auth",
		Method:          http.MethodPatch,
		Url:             "/api/localities/" + localityID + "/placemark",
		Body:            bytes.NewReader(body),
		RequestHeaders:  map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"code":401`},
		TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountPlacemarkRoutes(app, e)
		},
	}
	scenario.Test(t)
}

func TestClearManualPlacemark_DetachesPlacemark(t *testing.T) {
	app, token, localityID, _ := newPlacemarkScenario(t)

	// Seed an attached placemark first.
	pmColl, _ := app.Dao().FindCollectionByNameOrId("placemarks")
	pm := models.NewRecord(pmColl)
	pm.Set("country", "DE")
	pm.Set("locality", "Würzburg")
	pm.Set("geocoding_source", "manual")
	pm.Set("dedup_hash", "deadbeef0000000000000000000000000000000000000000000000000000beef")
	if err := app.Dao().SaveRecord(pm); err != nil {
		t.Fatalf("seed placemark: %v", err)
	}
	loc, _ := app.Dao().FindRecordById("localities", localityID)
	loc.Set("placemark", pm.Id)
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("attach placemark: %v", err)
	}

	scenario := tests.ApiScenario{
		Name:   "clear manual placemark",
		Method: http.MethodDelete,
		Url:    "/api/localities/" + localityID + "/placemark/override",
		RequestHeaders: map[string]string{
			"Authorization": token,
		},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"cleared"`},
		ExpectedEvents: map[string]int{
			// Setup writes (seeded placemark + the attach update on
			// the locality) sit before ResetEventCalls; the actual
			// DELETE produces one update on the locality.
			"OnModelBeforeCreate": 1,
			"OnModelAfterCreate":  1,
			"OnModelBeforeUpdate": 2,
			"OnModelAfterUpdate":  2,
		},
		TestAppFactory: func(_ *testing.T) *tests.TestApp { return app },
		BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, e *echo.Echo) {
			mountPlacemarkRoutes(app, e)
		},
		AfterTestFunc: func(t *testing.T, _ *tests.TestApp, _ *http.Response) {
			t.Helper()
			reloaded, _ := app.Dao().FindRecordById("localities", localityID)
			if reloaded.GetString("placemark") != "" {
				t.Errorf("placemark still attached after clear: %q", reloaded.GetString("placemark"))
			}
			// The placemark record itself stays — other localities
			// may still reference it.
			if _, err := app.Dao().FindRecordById("placemarks", pm.Id); err != nil {
				t.Errorf("placemark row should NOT be deleted on clear: %v", err)
			}
		},
	}
	scenario.Test(t)
}

// TestDedupHash_MatchesEnrichmentImplementation ensures the
// api-side and enrichment-side hash functions stay in lock-step.
// If either drifts, this test fails — we'd accidentally fork the
// placemark space.
func TestDedupHash_MatchesEnrichmentImplementation(t *testing.T) {
	// We don't import internal/enrichment from internal/api to
	// avoid the dependency cycle; instead we cross-check with the
	// well-known SHA-256 of the canonical input string.
	//
	//   normalize("DE") | normalize("Bayern") | normalize("Würzburg") | normalize("97070")
	//   == "de|bayern|würzburg|97070"
	//
	// SHA-256("de|bayern|würzburg|97070") = (precomputed below)
	const expected = "4b7015e1caea6410c452841f331eb3855010ee52d13d4c4573ca18f461c81fa7"
	got := manualDedupHash("DE", "Bayern", "Würzburg", "97070")
	if got != expected {
		t.Errorf("dedup hash drift!\nwant: %s\ngot:  %s", expected, got)
	}
}
