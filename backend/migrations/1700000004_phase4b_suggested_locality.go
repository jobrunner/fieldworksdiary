// Phase 4b — let the excursion-enrichment hook propose a locality.
//
// The user manually maintains `excursions.locality`. The hook only
// writes `suggested_locality` (nullable relation), the iOS view
// surfaces it as "Diese Exkursion liegt vermutlich im Fundort X —
// zuordnen?". If the user accepts, the iOS side copies the
// suggestion onto `locality`; otherwise the suggestion is ignored.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		excursions, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		localities, err := dao.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		excursions.Schema.AddField(&schema.SchemaField{
			Name: "suggested_locality",
			Type: schema.FieldTypeRelation,
			Options: &schema.RelationOptions{
				CollectionId:  localities.Id,
				CascadeDelete: false,
				MinSelect:     types.Pointer(0),
				MaxSelect:     types.Pointer(1),
			},
		})
		return dao.SaveCollection(excursions)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		if f := coll.Schema.GetFieldByName("suggested_locality"); f != nil {
			coll.Schema.RemoveField(f.Id)
		}
		return dao.SaveCollection(coll)
	})
}
