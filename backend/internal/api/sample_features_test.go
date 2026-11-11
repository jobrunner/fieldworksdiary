package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"go.mett.io/fwd-backend/internal/testutil"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func featuresScenario(app *tests.TestApp, token, sampleID string, body map[string]any, status int, content []string, after func(t testing.TB)) tests.ApiScenario {
	raw, _ := json.Marshal(body)
	sc := tests.ApiScenario{
		Name:   "features",
		Method: http.MethodPut,
		URL:    "/api/samples/" + sampleID + "/features",
		Body:   bytes.NewReader(raw),
		Headers: map[string]string{
			"Authorization": token,
			"Content-Type":  "application/json",
		},
		ExpectedStatus:  status,
		ExpectedContent: content,
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, e *core.ServeEvent) {
			bindSampleFeaturesRoute(e.Router)
		},
	}
	if status == http.StatusNoContent {
		sc.ExpectedEvents = map[string]int{"OnModelCreate": 1, "OnModelAfterCreateSuccess": 1}
	}
	if after != nil {
		sc.AfterTestFunc = func(t testing.TB, _ *tests.TestApp, _ *http.Response) { after(t) }
	}
	return sc
}

func TestFeaturesEndpoint_ReplacesSet(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fowner@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	token := authTokenFor(t, app, owner)
	app.ResetEventCalls()
	body := map[string]any{"features": []map[string]any{{
		"source_id": "nsg", "source_name": "NSG", "layer": "l", "feature_id": "7",
		"properties": map[string]any{"name": "Foo"}, "license": map[string]any{"name": "dl-de"},
	}}}
	sc := featuresScenario(app, token, sample.Id, body, http.StatusNoContent, nil, func(t testing.TB) {
		recs, err := app.FindRecordsByFilter("sample_features", "sample = {:s}", "", 0, 0, dbx.Params{"s": sample.Id})
		if err != nil || len(recs) != 1 || recs[0].GetString("owner") != owner.Id {
			t.Fatalf("recs = %d, err %v", len(recs), err)
		}
	})
	sc.Test(t)
}

func TestFeaturesEndpoint_ForeignSample404(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fowner@example.com")
	intruder := makeUser(t, app, "fintruder@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	token := authTokenFor(t, app, intruder)
	app.ResetEventCalls()
	s1 := featuresScenario(app, token, sample.Id, map[string]any{"features": []any{}},
		http.StatusNotFound, []string{`"status":404`}, nil)
	s1.Test(t)
}

func TestFeaturesEndpoint_MissingSample404(t *testing.T) {
	app := newScenarioApp(t)
	intruder := makeUser(t, app, "fintruder@example.com")
	token := authTokenFor(t, app, intruder)
	app.ResetEventCalls()
	s2 := featuresScenario(app, token, "doesnotexist00", map[string]any{"features": []any{}},
		http.StatusNotFound, []string{`"status":404`}, nil)
	s2.Test(t)
}

// newScenarioApp builds a test app without t.Cleanup: ApiScenario tears
// the app down itself and a second Cleanup hangs the PB logger hook.
func newScenarioApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app := testutil.NewTestApp(t)
	return app
}

func TestFeaturesEndpoint_MissingFeaturesKey400(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fowner@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	token := authTokenFor(t, app, owner)
	app.ResetEventCalls()
	sc := featuresScenario(app, token, sample.Id, map[string]any{},
		http.StatusBadRequest, []string{"features array is required"}, nil)
	sc.Test(t)
}
