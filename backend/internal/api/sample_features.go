package api

import (
	"encoding/json"
	"net/http"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// RegisterSampleFeaturesRoute wires `PUT /api/samples/{id}/features`.
func RegisterSampleFeaturesRoute(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindSampleFeaturesRoute(se.Router)
		return se.Next()
	})
}

func bindSampleFeaturesRoute(r *router.Router[*core.RequestEvent]) {
	r.PUT("/api/samples/{id}/features", handleReplaceSampleFeatures).
		Bind(apis.RequireAuth("users"))
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
func handleReplaceSampleFeatures(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	var body struct {
		Features *[]featureBody `json:"features"`
	}
	if err := bindJSON(e, &body); err != nil {
		return err
	}
	if body.Features == nil {
		return apis.NewBadRequestError("The features array is required.", nil)
	}
	app := e.App
	sample, err := app.FindRecordById("samples", e.Request.PathValue("id"))
	if err != nil || sample.GetString("owner") != ownerID {
		return apis.NewNotFoundError("sample not found", err)
	}
	fs := make([]geoplace.Feature, 0, len(*body.Features))
	for _, f := range *body.Features {
		fs = append(fs, geoplace.Feature{
			SourceID: f.SourceID, SourceName: f.SourceName, Layer: f.Layer,
			FeatureID: f.FeatureID, Properties: f.Properties, License: f.License,
		})
	}
	if err := geoplace.ReplaceFeatures(app, sample.Id, ownerID, fs); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "could not store features", err)
	}
	return e.NoContent(http.StatusNoContent)
}
