package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"go.mett.io/tabularius/internal/geoplace"
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

// handleReplaceSampleFeatures replaces the features of one scope of one
// of the caller's samples: `?scope=tempus` the Tempus rows, no parameter
// or `?scope=ortus` the Ortus rows (what app versions from before Tempus
// send). Rows of the other scope stay. With an explicit scope a feature
// of the other scope in the body is a 400; without one it is skipped. Foreign or missing samples both yield 404 so ids
// of other users' samples cannot be probed.
func handleReplaceSampleFeatures(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	rawScope := e.Request.URL.Query().Get("scope")
	scope, ok := featureScope(rawScope)
	if !ok {
		return apis.NewBadRequestError("Unknown feature scope.", nil)
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
		// Without a scope the caller is an app version from before
		// Tempus. It sends back every row it once pulled, the tempus:
		// ones included; those are the backend's and are skipped
		// instead of failing the request (the client would retry it
		// forever).
		if rawScope == "" && geoplace.ScopeOf(f.SourceID) != scope {
			continue
		}
		fs = append(fs, geoplace.Feature{
			SourceID: f.SourceID, SourceName: f.SourceName, Layer: f.Layer,
			FeatureID: f.FeatureID, Properties: f.Properties, License: f.License,
		})
	}
	if err := geoplace.ReplaceFeatures(app, sample.Id, ownerID, scope, fs); err != nil {
		if errors.Is(err, geoplace.ErrForeignScope) {
			return apis.NewBadRequestError("A feature does not belong to the requested scope.", nil)
		}
		return apis.NewApiError(http.StatusInternalServerError, "could not store features", err)
	}
	return e.NoContent(http.StatusNoContent)
}

// featureScope maps the scope query parameter; empty means Ortus.
func featureScope(raw string) (geoplace.FeatureScope, bool) {
	switch geoplace.FeatureScope(raw) {
	case "", geoplace.ScopeOrtus:
		return geoplace.ScopeOrtus, true
	case geoplace.ScopeTempus:
		return geoplace.ScopeTempus, true
	default:
		return "", false
	}
}
