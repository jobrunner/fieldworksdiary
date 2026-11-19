package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"go.mett.io/tabularius/internal/geoplace"
	"go.mett.io/tabularius/internal/testutil"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func featuresScenario(app *tests.TestApp, token, sampleID string, body map[string]any, status int, content []string, after func(t testing.TB)) tests.ApiScenario {
	sc := featuresScenarioQuery(app, token, sampleID, "", body, status, content, after)
	if status == http.StatusNoContent {
		sc.ExpectedEvents = map[string]int{"OnModelCreate": 1, "OnModelAfterCreateSuccess": 1}
	}
	return sc
}

// featuresScenarioQuery is featuresScenario with a raw query string
// ("scope=tempus"); it does not pin the model events.
func featuresScenarioQuery(app *tests.TestApp, token, sampleID, query string, body map[string]any, status int, content []string, after func(t testing.TB)) tests.ApiScenario {
	raw, _ := json.Marshal(body)
	url := "/api/samples/" + sampleID + "/features"
	if query != "" {
		url += "?" + query
	}
	sc := tests.ApiScenario{
		Name:   "features",
		Method: http.MethodPut,
		URL:    url,
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

func seedFeatures(t *testing.T, app *tests.TestApp, sampleID, ownerID string) {
	t.Helper()
	if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeOrtus,
		[]geoplace.Feature{{SourceID: "nsg", SourceName: "NSG", Layer: "l", FeatureID: "1"}}); err != nil {
		t.Fatal(err)
	}
	if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeTempus,
		[]geoplace.Feature{{SourceID: "tempus:sun", SourceName: "Tempus", Layer: "sun"}}); err != nil {
		t.Fatal(err)
	}
}

func featureSourceIDs(t testing.TB, app *tests.TestApp, sampleID string) string {
	t.Helper()
	recs, err := app.FindRecordsByFilter("sample_features", "sample = {:s}", "source_id", 0, 0, dbx.Params{"s": sampleID})
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(recs))
	for _, r := range recs {
		ids = append(ids, r.GetString("source_id"))
	}
	return strings.Join(ids, ",")
}

// An app version from before Tempus sends only its Ortus features; the
// Tempus rows the backend wrote must survive that.
func TestFeaturesEndpoint_LegacyPutKeepsTempusRows(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fscope1@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	seedFeatures(t, app, sample.Id, owner.Id)
	token := authTokenFor(t, app, owner)
	body := map[string]any{"features": []map[string]any{{"source_id": "ffh", "source_name": "FFH", "layer": "l", "feature_id": "9"}}}
	sc := featuresScenarioQuery(app, token, sample.Id, "scope=ortus", body, http.StatusNoContent, nil, func(t testing.TB) {
		if got := featureSourceIDs(t, app, sample.Id); got != "ffh,tempus:sun" {
			t.Errorf("sources = %q", got)
		}
	})
	sc.Test(t)
}

func TestFeaturesEndpoint_NoScopeMeansOrtus(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fscope2@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	seedFeatures(t, app, sample.Id, owner.Id)
	token := authTokenFor(t, app, owner)
	sc := featuresScenarioQuery(app, token, sample.Id, "", map[string]any{"features": []any{}}, http.StatusNoContent, nil, func(t testing.TB) {
		if got := featureSourceIDs(t, app, sample.Id); got != "tempus:sun" {
			t.Errorf("sources = %q", got)
		}
	})
	sc.Test(t)
}

func TestFeaturesEndpoint_TempusScopeReplacesOnlyTempus(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fscope3@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	seedFeatures(t, app, sample.Id, owner.Id)
	token := authTokenFor(t, app, owner)
	body := map[string]any{"features": []map[string]any{{
		"source_id": "tempus:moon", "source_name": "Tempus", "layer": "moon",
		"properties": map[string]any{"illuminationPct": 14.19}, "license": map[string]any{"name": "Meeus"},
	}}}
	sc := featuresScenarioQuery(app, token, sample.Id, "scope=tempus", body, http.StatusNoContent, nil, func(t testing.TB) {
		if got := featureSourceIDs(t, app, sample.Id); got != "nsg,tempus:moon" {
			t.Errorf("sources = %q", got)
		}
	})
	sc.Test(t)
}

func TestFeaturesEndpoint_ForeignScopeInBody400(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fscope4@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	seedFeatures(t, app, sample.Id, owner.Id)
	token := authTokenFor(t, app, owner)
	body := map[string]any{"features": []map[string]any{{"source_id": "nsg", "source_name": "NSG", "layer": "l"}}}
	sc := featuresScenarioQuery(app, token, sample.Id, "scope=tempus", body, http.StatusBadRequest, []string{`"status":400`}, func(t testing.TB) {
		if got := featureSourceIDs(t, app, sample.Id); got != "nsg,tempus:sun" {
			t.Errorf("rows changed after a rejected request: %q", got)
		}
	})
	sc.Test(t)
}

func TestFeaturesEndpoint_UnknownScope400(t *testing.T) {
	app := newScenarioApp(t)
	owner := makeUser(t, app, "fscope5@example.com")
	ft := makeFieldtrip(t, app, owner.Id)
	sample := makeSample(t, app, owner.Id, "260519/1", ft.Id)
	token := authTokenFor(t, app, owner)
	sc := featuresScenarioQuery(app, token, sample.Id, "scope=alles", map[string]any{"features": []any{}},
		http.StatusBadRequest, []string{`"status":400`}, nil)
	sc.Test(t)
}
