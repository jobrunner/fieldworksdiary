package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/apis"

	"go.mett.io/fwd-backend/internal/version"
)

// mountVersionRoute spiegelt RegisterVersionRoute fürs Test-Setup
// (apis.InitApi triggert OnBeforeServe nicht — siehe mountExportRoute
// in export_test.go für dasselbe Muster).
func mountVersionRoute(e *echo.Echo) {
	e.GET("/api/version", handleVersion)
}

func TestVersionRoute_ReturnsCurrentBuildIdentity(t *testing.T) {
	app := setupTestApp(t)

	origVersion, origCommit := version.Version, version.Commit
	version.Version = "1.2.3"
	version.Commit = "abc1234"
	t.Cleanup(func() {
		version.Version, version.Commit = origVersion, origCommit
	})

	e, err := apis.InitApi(app)
	if err != nil {
		t.Fatalf("InitApi: %v", err)
	}
	mountVersionRoute(e)

	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var got version.Info
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if got.Version != "1.2.3" {
		t.Errorf("version = %q, want %q", got.Version, "1.2.3")
	}
	if got.Commit != "abc1234" {
		t.Errorf("commit = %q, want %q", got.Commit, "abc1234")
	}
}
