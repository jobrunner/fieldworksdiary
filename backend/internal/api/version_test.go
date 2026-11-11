package api

import (
	"net/http"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/fwd-backend/internal/version"
)

func TestVersionRoute_ReturnsCurrentBuildIdentity(t *testing.T) {
	app := setupTestApp(t)

	origVersion, origCommit := version.Version, version.Commit
	version.Version = "1.2.3"
	version.Commit = "abc1234"
	t.Cleanup(func() {
		version.Version, version.Commit = origVersion, origCommit
	})

	scenario := tests.ApiScenario{
		Name:            "version route",
		Method:          http.MethodGet,
		URL:             "/api/version",
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"version":"1.2.3"`, `"commit":"abc1234"`},
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		BeforeTestFunc: func(_ testing.TB, _ *tests.TestApp, e *core.ServeEvent) {
			bindVersionRoute(e.Router)
		},
	}
	scenario.Test(t)
}
