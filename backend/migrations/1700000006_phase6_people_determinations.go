// Phase 6 — determinations and people.
//
// `people` is a tiny reference table (full_name, abbreviation for
// labels, optional email). `determinations` links a sample to a
// species_text + kind (det. / t. / vid.) + the person who made the
// call. Multiple determinations per sample are normal — the most
// recent det. wins, t./vid. are corroborating notes.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		open := types.Pointer("")

		// 1. people
		people := &models.Collection{
			Name: "people",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "full_name", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "abbreviation", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "email", Type: schema.FieldTypeEmail},
				&schema.SchemaField{Name: "notes", Type: schema.FieldTypeEditor},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_people_full_name ON people (full_name)",
			},
			ListRule:   open,
			ViewRule:   open,
			CreateRule: open,
			UpdateRule: open,
			DeleteRule: open,
		}
		if err := dao.SaveCollection(people); err != nil {
			return err
		}

		// 2. determinations
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		determinations := &models.Collection{
			Name: "determinations",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{
					Name:     "sample",
					Type:     schema.FieldTypeRelation,
					Required: true,
					Options: &schema.RelationOptions{
						CollectionId:  samples.Id,
						CascadeDelete: true, // determination dies with its sample
						MinSelect:     types.Pointer(1),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "species_text", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{
					Name:     "kind",
					Type:     schema.FieldTypeSelect,
					Required: true,
					Options: &schema.SelectOptions{
						Values:    []string{"det", "t", "vid"},
						MaxSelect: 1,
					},
				},
				&schema.SchemaField{
					Name: "person",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  people.Id,
						CascadeDelete: false,
						MinSelect:     types.Pointer(0),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "determined_on", Type: schema.FieldTypeDate},
				&schema.SchemaField{Name: "notes", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "client_uuid", Type: schema.FieldTypeText},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_determinations_sample ON determinations (sample)",
				"CREATE INDEX idx_determinations_kind ON determinations (kind)",
				"CREATE INDEX idx_determinations_person ON determinations (person)",
			},
			ListRule:   open,
			ViewRule:   open,
			CreateRule: open,
			UpdateRule: open,
			DeleteRule: open,
		}
		return dao.SaveCollection(determinations)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		for _, name := range []string{"determinations", "people"} {
			if c, err := dao.FindCollectionByNameOrId(name); err == nil {
				if err := dao.DeleteCollection(c); err != nil {
					return err
				}
			}
		}
		return nil
	})
}
