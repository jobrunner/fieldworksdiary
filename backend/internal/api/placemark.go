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
	"encoding/json"
	"net/http"
	"strings"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/geoplace"
)

// RegisterPlacemarkOverrideRoutes wires the two manual-override
// endpoints. Call from `main.go`.
func RegisterPlacemarkOverrideRoutes(app core.App) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		requireAuth := apis.RequireRecordAuth("users")
		e.Router.PATCH("/api/localities/:id/placemark", func(c echo.Context) error {
			return handleSetManualPlacemark(app, c)
		}, requireAuth)
		e.Router.DELETE("/api/localities/:id/placemark/override", func(c echo.Context) error {
			return handleClearManualPlacemark(app, c)
		}, requireAuth)
		return nil
	})
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
	if iso == "" {
		return geoplace.Place{}, apis.NewBadRequestError("Country code (country_iso) is required.", nil)
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

func handleSetManualPlacemark(app core.App, c echo.Context) error {
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	localityID := c.PathParam("id")
	if localityID == "" {
		return apis.NewBadRequestError("missing locality id", nil)
	}

	body, err := decodeJSONMap(c)
	if err != nil {
		return err
	}
	place, err := placeFromBody(body)
	if err != nil {
		return err
	}

	dao := app.Dao()
	loc, err := dao.FindRecordById("localities", localityID)
	if err != nil {
		return apis.NewNotFoundError("locality not found", err)
	}
	if loc.GetString("owner") != ownerID {
		return apis.NewForbiddenError("locality does not belong to authenticated user", nil)
	}

	// Manual rows are scoped per owner, so the auto-geocoder never
	// overwrites them and other users never see them.
	pm, err := geoplace.LookupOrCreatePlacemark(dao, place, "manual", ownerID)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not persist placemark", err)
	}

	loc.Set("placemark", pm.Id)
	if err := dao.SaveRecord(loc); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not attach placemark", err)
	}
	return c.JSON(http.StatusOK, pm)
}

func handleClearManualPlacemark(app core.App, c echo.Context) error {
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	localityID := c.PathParam("id")
	if localityID == "" {
		return apis.NewBadRequestError("missing locality id", nil)
	}

	dao := app.Dao()
	loc, err := dao.FindRecordById("localities", localityID)
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
		return c.JSON(http.StatusOK, map[string]any{"status": "no-op"})
	}
	loc.Set("placemark", "")
	if err := dao.SaveRecord(loc); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not clear placemark", err)
	}
	return c.JSON(http.StatusOK, map[string]any{"status": "cleared"})
}

// decodeJSONMap reads the request body as a JSON object. c.Bind is not
// used because it tries to bind path params into the map (PATCH route).
func decodeJSONMap(c echo.Context) (map[string]any, error) {
	var body map[string]any
	if err := json.NewDecoder(c.Request().Body).Decode(&body); err != nil {
		return nil, apis.NewBadRequestError("Invalid request body.", err)
	}
	return body, nil
}

// RegisterPlacemarkResolveRoute wires `POST /api/placemarks/resolve`.
func RegisterPlacemarkResolveRoute(app core.App) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		e.Router.POST("/api/placemarks/resolve", func(c echo.Context) error {
			return handleResolvePlacemark(app, c)
		}, apis.RequireRecordAuth("users"))
		return nil
	})
}

// handleResolvePlacemark looks up or creates the placemark for the flat
// place fields. `manual` rows are owned by the caller; `backend_service`
// rows are shared and carry no owner.
func handleResolvePlacemark(app core.App, c echo.Context) error {
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	body, err := decodeJSONMap(c)
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
	pm, err := geoplace.LookupOrCreatePlacemark(app.Dao(), place, source, owner)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not persist placemark", err)
	}
	return c.JSON(http.StatusOK, pm)
}
