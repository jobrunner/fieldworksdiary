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
func resetStaleLocationStatus(rec *core.Record) {
	orig := rec.Original()
	moved := math.Abs(rec.GetFloat("latitude")-orig.GetFloat("latitude")) > coordEpsilon ||
		math.Abs(rec.GetFloat("longitude")-orig.GetFloat("longitude")) > coordEpsilon
	if !moved {
		return
	}
	status := rec.GetString("location_status")
	if status != "backend_service" || status != orig.GetString("location_status") {
		return
	}
	if rec.GetString("placemark") != orig.GetString("placemark") {
		return
	}
	rec.Set("location_status", "pending")
}
