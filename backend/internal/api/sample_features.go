package api

import (
	"encoding/json"
	"net/http"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// RegisterSampleFeaturesRoute wires `PUT /api/samples/:id/features`.
func RegisterSampleFeaturesRoute(app core.App) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		e.Router.PUT("/api/samples/:id/features", func(c echo.Context) error {
			return handleReplaceSampleFeatures(app, c)
		}, apis.RequireRecordAuth("users"))
		return nil
	})
}

type featureBody struct {
	SourceID   string          `json:"source_id"`
	SourceName string          `json:"source_name"`
	Layer      string          `json:"layer"`
	FeatureID  string          `json:"feature_id"`
	Properties map[string]any  `json:"properties"`
	License    json.RawMessage `json:"license"`
}

// handleReplaceSampleFeatures replaces the complete feature set of one of
// the caller's samples. Foreign or missing samples both yield 404 so ids
// of other users' samples cannot be probed.
func handleReplaceSampleFeatures(app core.App, c echo.Context) error {
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	var body struct {
		Features []featureBody `json:"features"`
	}
	if err := c.Bind(&body); err != nil {
		return apis.NewBadRequestError("Invalid request body.", err)
	}
	dao := app.Dao()
	sample, err := dao.FindRecordById("samples", c.PathParam("id"))
	if err != nil || sample.GetString("owner") != ownerID {
		return apis.NewNotFoundError("sample not found", err)
	}
	fs := make([]geoplace.Feature, 0, len(body.Features))
	for _, f := range body.Features {
		fs = append(fs, geoplace.Feature{
			SourceID: f.SourceID, SourceName: f.SourceName, Layer: f.Layer,
			FeatureID: f.FeatureID, Properties: f.Properties, License: f.License,
		})
	}
	if err := geoplace.ReplaceFeatures(dao, sample.Id, ownerID, fs); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not store features", err)
	}
	return c.NoContent(http.StatusNoContent)
}
