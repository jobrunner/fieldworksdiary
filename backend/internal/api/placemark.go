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
// Both routes are owner-scoped: the locality has to belong to the
// authenticated user, otherwise the call gets a 403. We could
// rely on PocketBase's `viewRule = "@request.auth.id != '' &&
// owner = @request.auth.id"` for the lookup, but checking
// explicitly here keeps the error message human-readable.
package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
	"golang.org/x/text/unicode/norm"
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

// manualPlacemarkRequest is the payload for PATCH. All fields are
// optional except `country` (Placemark schema requires ISO-2).
type manualPlacemarkRequest struct {
	Country               string `json:"country"`
	AdministrativeArea    string `json:"administrative_area"`
	SubAdministrativeArea string `json:"sub_administrative_area"`
	Locality              string `json:"locality"`
	SubLocality           string `json:"sub_locality"`
	PostalCode            string `json:"postal_code"`
	Name                  string `json:"name"`
	Thoroughfare          string `json:"thoroughfare"`
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

	var req manualPlacemarkRequest
	if err := c.Bind(&req); err != nil {
		return apis.NewBadRequestError("Invalid request body.", err)
	}
	country := strings.ToUpper(strings.TrimSpace(req.Country))
	if len(country) != 2 {
		return apis.NewBadRequestError("country must be an ISO 3166-1 alpha-2 code", nil)
	}

	dao := app.Dao()
	loc, err := dao.FindRecordById("localities", localityID)
	if err != nil {
		return apis.NewNotFoundError("locality not found", err)
	}
	if loc.GetString("owner") != ownerID {
		return apis.NewForbiddenError("locality does not belong to authenticated user", nil)
	}

	hash := manualDedupHash(country, req.AdministrativeArea, req.Locality, req.PostalCode)

	// Lookup-or-create with `geocoding_source = manual` so the
	// auto-geocoder hook (R7.1) won't try to overwrite it.
	pm, err := lookupOrCreateManualPlacemark(dao, hash, req)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not persist placemark", err)
	}

	// Promote to manual if we matched an existing backend-service row.
	// (Same coords + fields a future labelloc roll-out might produce —
	// without this flip a re-geocode would overwrite the user's call.)
	if pm.GetString("geocoding_source") != "manual" {
		pm.Set("geocoding_source", "manual")
		pm.Set("geocoding_date", time.Now())
		if err := dao.SaveRecord(pm); err != nil {
			return apis.NewApiError(http.StatusInternalServerError, "could not promote placemark to manual", err)
		}
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

// lookupOrCreateManualPlacemark mirrors `enrichment.lookupOrCreatePlacemark`
// but writes `geocoding_source = "manual"` on create and persists
// every field the request supplied (including the ones the
// auto-path doesn't bother to fill, like postal_code).
func lookupOrCreateManualPlacemark(dao *daos.Dao, hash string, req manualPlacemarkRequest) (*models.Record, error) {
	existing, err := dao.FindFirstRecordByFilter(
		"placemarks",
		"dedup_hash = {:h}",
		dbx.Params{"h": hash},
	)
	if err == nil && existing != nil {
		return existing, nil
	}
	coll, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return nil, err
	}
	rec := models.NewRecord(coll)
	rec.Set("country", strings.ToUpper(strings.TrimSpace(req.Country)))
	rec.Set("administrative_area", req.AdministrativeArea)
	rec.Set("sub_administrative_area", req.SubAdministrativeArea)
	rec.Set("locality", req.Locality)
	rec.Set("sub_locality", req.SubLocality)
	rec.Set("postal_code", req.PostalCode)
	rec.Set("name", req.Name)
	rec.Set("thoroughfare", req.Thoroughfare)
	rec.Set("geocoding_source", "manual")
	rec.Set("geocoding_date", time.Now())
	rec.Set("dedup_hash", hash)
	if err := dao.SaveRecord(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// manualDedupHash mirrors `enrichment.PlacemarkDedupHash`. Kept as
// a local copy because the api package shouldn't import enrichment;
// the canonical algorithm is documented in `enrichment/placemark.go`
// and the two implementations are kept in sync by unit tests on
// both sides (any drift surfaces as failing equality assertions).
func manualDedupHash(country, administrativeArea, locality, postalCode string) string {
	parts := []string{
		manualNormalize(country),
		manualNormalize(administrativeArea),
		manualNormalize(locality),
		manualNormalize(postalCode),
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:])
}

func manualNormalize(s string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(s)))
}

// Used only as a compile-time placeholder to keep the json import
// honest when this file lives alone — see `c.Bind` above already
// reaches into encoding/json transitively, but the linter doesn't
// always agree.
var _ = json.RawMessage{}
