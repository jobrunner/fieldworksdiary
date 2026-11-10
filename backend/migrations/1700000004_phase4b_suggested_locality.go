// Phase 4b — let the excursion-enrichment hook propose a locality.
//
// The user manually maintains `excursions.locality`. The hook only
// writes `suggested_locality` (nullable relation), the iOS view
// surfaces it as "Diese Exkursion liegt vermutlich im Fundort X —
// zuordnen?". If the user accepts, the iOS side copies the
// suggestion onto `locality`; otherwise the suggestion is ignored.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		excursions, err := app.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		excursions.Fields.Add(&core.RelationField{
			Name:          "suggested_locality",
			CollectionId:  localities.Id,
			CascadeDelete: false,
			MinSelect:     0,
			MaxSelect:     1,
		})
		return app.Save(excursions)
	}, func(app core.App) error {
		coll, err := app.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		removeFields(coll, "suggested_locality")
		return app.Save(coll)
	})
}
