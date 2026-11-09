// Phase O.3 — `sample_features`: external geo features (protected areas,
// habitats, …) attached to a sample, with source and license info.
// Owner-scoped read; writes are backend-only.
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
		if c, err := dao.FindCollectionByNameOrId("sample_features"); err == nil && c != nil {
			return nil
		}
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		rule := types.Pointer("@request.auth.id != '' && owner = @request.auth.id")
		return dao.SaveCollection(&models.Collection{
			Name: "sample_features",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{
					Name: "owner", Type: schema.FieldTypeRelation, Required: true,
					Options: &schema.RelationOptions{
						CollectionId: users.Id,
						MinSelect:    types.Pointer(1),
						MaxSelect:    types.Pointer(1),
					},
				},
				&schema.SchemaField{
					Name: "sample", Type: schema.FieldTypeRelation, Required: true,
					Options: &schema.RelationOptions{
						CollectionId:  samples.Id,
						CascadeDelete: true,
						MinSelect:     types.Pointer(1),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "source_id", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "source_name", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "layer", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "feature_id", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "properties", Type: schema.FieldTypeJson,
					Options: &schema.JsonOptions{MaxSize: 2 << 20}},
				&schema.SchemaField{Name: "license", Type: schema.FieldTypeJson,
					Options: &schema.JsonOptions{MaxSize: 2 << 20}},
				&schema.SchemaField{Name: "fetched_at", Type: schema.FieldTypeDate},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_sample_features_sample_source ON sample_features (sample, source_id)",
			},
			ListRule: rule,
			ViewRule: rule,
		})
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		if c, err := dao.FindCollectionByNameOrId("sample_features"); err == nil && c != nil {
			return dao.DeleteCollection(c)
		}
		return nil
	})
}
