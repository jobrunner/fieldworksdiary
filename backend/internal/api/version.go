// GET /api/version — public, unauthenticated build-identity endpoint.
// The iOS "Status" screen calls this to show which backend build it
// is talking to, next to the app's own version.
package api

import (
	"net/http"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"go.mett.io/fwd-backend/internal/version"
)

// RegisterVersionRoute wires `GET /api/version`. Call from `main.go`.
func RegisterVersionRoute(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindVersionRoute(se.Router)
		return se.Next()
	})
}

func bindVersionRoute(r *router.Router[*core.RequestEvent]) {
	r.GET("/api/version", handleVersion)
}

func handleVersion(e *core.RequestEvent) error {
	return e.JSON(http.StatusOK, version.Current())
}
