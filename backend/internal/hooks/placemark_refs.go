package hooks

import (
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"

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
// Admin requests are not checked.
func RegisterPlacemarkRefGuards(app core.App) {
	for name := range placemarkRefFields {
		app.OnRecordBeforeCreateRequest(name).Add(func(e *core.RecordCreateEvent) error {
			return guardPlacemarkRefs(app.Dao(), e.HttpContext, e.Record)
		})
		app.OnRecordBeforeUpdateRequest(name).Add(func(e *core.RecordUpdateEvent) error {
			return guardPlacemarkRefs(app.Dao(), e.HttpContext, e.Record)
		})
	}
}

func guardPlacemarkRefs(dao *daos.Dao, c interface{ Get(string) any }, rec *models.Record) error {
	if admin, _ := c.Get(apis.ContextAdminKey).(*models.Admin); admin != nil {
		return nil
	}
	callerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	return checkPlacemarkRefs(dao, rec, callerID)
}

// checkPlacemarkRefs validates the placemark reference fields of rec
// that are set (create) or changed (update) against the visibility
// rule for callerID.
func checkPlacemarkRefs(dao *daos.Dao, rec *models.Record, callerID string) error {
	fields := placemarkRefFields[rec.Collection().Name]
	var original *models.Record
	if !rec.IsNew() {
		original = rec.OriginalCopy()
	}
	for _, field := range fields {
		id := rec.GetString(field)
		if id == "" {
			continue
		}
		if original != nil && original.GetString(field) == id {
			continue
		}
		pm, err := dao.FindRecordById("placemarks", id)
		if err != nil || !geoplace.VisibleTo(pm, callerID) {
			return apis.NewBadRequestError("Invalid placemark reference.", map[string]any{
				field: map[string]string{
					"code":    "validation_invalid_placemark",
					"message": "Placemark is not accessible.",
				},
			})
		}
	}
	return nil
}
