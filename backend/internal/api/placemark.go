// Phase R7.2 — manual-override endpoint for Locality.placemark.
//
// Two routes:
//
//   - `PATCH /api/localities/:id/placemark` accepts the corrected
//     placemark fields. The handler looks up (or creates) a
//     placemark row with `geocoding_source = "manual"` so the
//     auto-geocoder hook (R7.1) leaves it alone, and points the
//     locality at it.
//   - `DELETE /api/localities/:id/placemark/override` removes the
//     manual lock by detaching the placemark; the locality's next
//     update tick re-runs the auto-geocode hook (placemark is
//     empty → fusion-style "needs re-fuse" branch fires).
//
// The PATCH body carries the same flat place fields as
// `POST /api/placemarks/resolve` (without `geocoding_source`).
//
// Both routes are owner-scoped: the locality has to belong to the
// authenticated user, otherwise the call gets a 403. We could rely on
// PocketBase's owner-scoped viewRule (require an authenticated
// `@request.auth.id` plus `owner = @request.auth.id`) for the lookup,
// but checking explicitly here keeps the error message human-readable.
package api

import (
	"net/http"
	"strings"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/geoplace"
)

// RegisterPlacemarkOverrideRoutes wires the two manual-override
// endpoints. Call from `main.go`.
func RegisterPlacemarkOverrideRoutes(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindPlacemarkOverrideRoutes(se.Router)
		return se.Next()
	})
}

func bindPlacemarkOverrideRoutes(r *router.Router[*core.RequestEvent]) {
	r.PATCH("/api/localities/{id}/placemark", handleSetManualPlacemark).
		Bind(apis.RequireAuth("users"))
	r.DELETE("/api/localities/{id}/placemark/override", handleClearManualPlacemark).
		Bind(apis.RequireAuth("users"))
}

// placeFromBody builds a Place from the flat placemark body shared by
// `/api/placemarks/resolve` and the manual override. Unknown keys are
// ignored; an empty `country_iso` is an error.
func placeFromBody(body map[string]any) (geoplace.Place, error) {
	str := func(k string) string {
		v, _ := body[k].(string)
		return strings.TrimSpace(v)
	}
	iso := strings.ToUpper(str("country_iso"))
	if len(iso) != 2 || !isASCIILetters(iso) {
		return geoplace.Place{}, apis.NewBadRequestError("Country code (country_iso) must be exactly 2 letters.", nil)
	}
	p := geoplace.Place{
		CountryISO:    iso,
		Admin:         map[adminlabels.Tier]geoplace.AdminValue{},
		Island:        str("island"),
		MountainRange: str("mountain_range"),
		Mountain:      str("mountain"),
	}
	for _, t := range adminlabels.Tiers {
		k := string(t)
		v := geoplace.AdminValue{Name: str(k), Native: str(k + "_native")}
		if lvl, ok := body[k+"_level"].(float64); ok {
			v.Level = int(lvl)
		}
		if v != (geoplace.AdminValue{}) {
			p.Admin[t] = v
		}
	}
	return p, nil
}

func handleSetManualPlacemark(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	localityID := e.Request.PathValue("id")
	if localityID == "" {
		return apis.NewBadRequestError("missing locality id", nil)
	}

	body, err := decodeJSONMap(e)
	if err != nil {
		return err
	}
	place, err := placeFromBody(body)
	if err != nil {
		return err
	}

	app := e.App
	loc, err := app.FindRecordById("localities", localityID)
	if err != nil {
		return apis.NewNotFoundError("locality not found", err)
	}
	if loc.GetString("owner") != ownerID {
		return apis.NewForbiddenError("locality does not belong to authenticated user", nil)
	}

	// Manual rows are scoped per owner, so the auto-geocoder never
	// overwrites them and other users never see them.
	pm, err := geoplace.LookupOrCreatePlacemark(app, place, "manual", ownerID)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not persist placemark", err)
	}

	loc.Set("placemark", pm.Id)
	if err := app.SaveNoValidate(loc); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not attach placemark", err)
	}
	return e.JSON(http.StatusOK, pm)
}

func handleClearManualPlacemark(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	localityID := e.Request.PathValue("id")
	if localityID == "" {
		return apis.NewBadRequestError("missing locality id", nil)
	}

	app := e.App
	loc, err := app.FindRecordById("localities", localityID)
	if err != nil {
		return apis.NewNotFoundError("locality not found", err)
	}
	if loc.GetString("owner") != ownerID {
		return apis.NewForbiddenError("locality does not belong to authenticated user", nil)
	}

	// Just detach. We don't delete the placemark row — other
	// localities may still be pointing at it. The locality's next
	// auto-geocode tick will repopulate (R7.1 hook fires because
	// `placemark` is now empty).
	if loc.GetString("placemark") == "" {
		return e.JSON(http.StatusOK, map[string]any{"status": "no-op"})
	}
	loc.Set("placemark", "")
	if err := app.SaveNoValidate(loc); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not clear placemark", err)
	}
	return e.JSON(http.StatusOK, map[string]any{"status": "cleared"})
}

func isASCIILetters(s string) bool {
	for _, r := range s {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

// decodeJSONMap reads the request body as a JSON object; an empty or
// malformed body is a 400.
func decodeJSONMap(e *core.RequestEvent) (map[string]any, error) {
	var body map[string]any
	if err := e.BindBody(&body); err != nil || body == nil {
		return nil, apis.NewBadRequestError("Invalid request body.", err)
	}
	return body, nil
}

// bindJSON reads the request body into dst via PocketBase's BindBody
// (which keeps the body re-readable for RequestInfo). Like echo's c.Bind
// in PocketBase 0.22, an empty body leaves dst untouched (the handler's
// own required-field checks answer), a malformed one is a 400.
func bindJSON(e *core.RequestEvent, dst any) error {
	if err := e.BindBody(dst); err != nil {
		return apis.NewBadRequestError("Invalid request body.", err)
	}
	return nil
}

// RegisterPlacemarkResolveRoute wires `POST /api/placemarks/resolve`.
func RegisterPlacemarkResolveRoute(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindPlacemarkResolveRoute(se.Router)
		return se.Next()
	})
}

func bindPlacemarkResolveRoute(r *router.Router[*core.RequestEvent]) {
	r.POST("/api/placemarks/resolve", handleResolvePlacemark).
		Bind(apis.RequireAuth("users"))
}

// handleResolvePlacemark looks up or creates the placemark for the flat
// place fields. `manual` rows are owned by the caller; `backend_service`
// rows are shared and carry no owner.
func handleResolvePlacemark(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	body, err := decodeJSONMap(e)
	if err != nil {
		return err
	}
	source, _ := body["geocoding_source"].(string)
	if source != "backend_service" && source != "manual" {
		return apis.NewBadRequestError("The geocoding_source must be backend_service or manual.", nil)
	}
	place, err := placeFromBody(body)
	if err != nil {
		return err
	}
	owner := ""
	if source == "manual" {
		owner = ownerID
	}
	pm, err := geoplace.LookupOrCreatePlacemark(e.App, place, source, owner)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not persist placemark", err)
	}
	return e.JSON(http.StatusOK, pm)
}
