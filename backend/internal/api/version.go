// GET /api/version — public, unauthenticated build-identity endpoint.
// The iOS "Status" screen calls this to show which backend build it
// is talking to, next to the app's own version.
package api

import (
	"net/http"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/fwd-backend/internal/version"
)

// RegisterVersionRoute wires `GET /api/version`. Call from `main.go`.
func RegisterVersionRoute(app core.App) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		e.Router.GET("/api/version", handleVersion)
		return nil
	})
}

func handleVersion(c echo.Context) error {
	return c.JSON(http.StatusOK, version.Current())
}
