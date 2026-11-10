package hooks

import (
	"errors"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// placemarkRefFields lists, per collection, the relation fields that
// point at `placemarks`. The relation validator only checks that the
// target exists, so without this guard a user could reference (and
// thereby read via expand/labels/export) another user's manual
// placemark.
var placemarkRefFields = map[string][]string{
	"samples":    {"placemark", "placemark_suggestion"},
	"localities": {"placemark"},
}

// RegisterPlacemarkRefGuards rejects (400) create/update requests on
// samples and localities that set a placemark reference to a row the
// caller may not see (neither shared nor owned, see geoplace.VisibleTo).
// Superuser requests are not checked.
func RegisterPlacemarkRefGuards(app core.App) {
	for name := range placemarkRefFields {
		guard := func(e *core.RecordRequestEvent) error {
			if err := guardPlacemarkRefs(e.App, e.Auth, e.Record); err != nil {
				return err
			}
			return e.Next()
		}
		app.OnRecordCreateRequest(name).BindFunc(guard)
		app.OnRecordUpdateRequest(name).BindFunc(guard)
	}
}

func guardPlacemarkRefs(app core.App, auth *core.Record, rec *core.Record) error {
	if auth != nil && auth.IsSuperuser() {
		return nil
	}
	callerID, err := authOwnerID(auth)
	if err != nil {
		return err
	}
	return checkPlacemarkRefs(app, rec, callerID)
}

// checkPlacemarkRefs validates the placemark reference fields of rec
// that are set (create) or changed (update) against the visibility
// rule for callerID.
func checkPlacemarkRefs(app core.App, rec *core.Record, callerID string) error {
	fields := placemarkRefFields[rec.Collection().Name]
	var original *core.Record
	if !rec.IsNew() {
		original = rec.Original()
	}
	for _, field := range fields {
		id := rec.GetString(field)
		if id == "" {
			continue
		}
		if original != nil && original.GetString(field) == id {
			continue
		}
		pm, err := app.FindRecordById("placemarks", id)
		if err != nil || !geoplace.VisibleTo(pm, callerID) {
			// The field error is a plain error on purpose: PocketBase
			// renders it as {"code":"validation_invalid_value",
			// "message":"Invalid value."}, exactly the body 0.22 sent
			// (its nested map[string]string was flattened the same way;
			// 0.23+ would nest it one level deeper and the iOS error
			// formatter would drop the field).
			return apis.NewBadRequestError("Invalid placemark reference.", map[string]error{
				field: errors.New("placemark is not accessible"),
			})
		}
	}
	return nil
}
