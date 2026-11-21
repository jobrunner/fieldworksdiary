package hooks

import (
	"math"

	"github.com/pocketbase/pocketbase/core"
)

// coordEpsilon mirrors enrichment.coordEpsilon: smaller latitude/
// longitude changes are float noise from the 6-decimal round trip.
const coordEpsilon = 1e-7

// RegisterSampleLocationReset wires resetStaleLocationStatus as a
// update request hook on samples (before the save).
func RegisterSampleLocationReset(app core.App) {
	app.OnRecordUpdateRequest("samples").BindFunc(func(e *core.RecordRequestEvent) error {
		resetStaleLocationStatus(e.Record)
		return e.Next()
	})
}

// resetStaleLocationStatus sets location_status back to "pending" when
// the coordinate of a backend_service sample moved but the client sent
// neither a new status nor a new placemark. Otherwise the enrichment
// (which skips backend_service samples) would never re-resolve the place
// and the old placemark would stick to the new coordinate. A client that
// re-resolved online sends the new placemark and keeps its status.
// A move also removes a DEM height of the old place (dropStaleDEMHeight).
func resetStaleLocationStatus(rec *core.Record) {
	orig := rec.Original()
	moved := math.Abs(rec.GetFloat("latitude")-orig.GetFloat("latitude")) > coordEpsilon ||
		math.Abs(rec.GetFloat("longitude")-orig.GetFloat("longitude")) > coordEpsilon
	if !moved {
		return
	}
	status := rec.GetString("location_status")
	if status == "backend_service" && status == orig.GetString("location_status") &&
		rec.GetString("placemark") == orig.GetString("placemark") {
		rec.Set("location_status", "pending")
	}
	dropStaleDEMHeight(rec, orig)
}

// dropStaleDEMHeight removes a DEM height (elevation_source
// backend_service) after a coordinate move: it was read for the old
// place, and what works with the height (the Tempus query) must not use
// it for the new one. The Ortus run that follows writes the new height.
// It stays when the client sent a height of its own with the move, and
// when no Ortus run follows (status backend_service: the client
// resolved the place itself).
func dropStaleDEMHeight(rec, orig *core.Record) {
	if rec.GetString("elevation_source") != "backend_service" ||
		orig.GetString("elevation_source") != "backend_service" ||
		rec.GetFloat("elevation") != orig.GetFloat("elevation") ||
		rec.GetString("location_status") == "backend_service" {
		return
	}
	rec.Set("elevation", 0)
	rec.Set("elevation_source", "")
	rec.Set("vertical_accuracy", 0)
}
