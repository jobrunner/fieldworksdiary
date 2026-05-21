// Phase 14 — sample_photos collection.
//
// One row per photo attached to a sample. We use a separate collection
// (rather than a file array on `samples`) because:
//   - photos can be uploaded individually after the sample is created;
//     useful when the network is patchy in the field,
//   - each upload is its own multipart request — no all-or-nothing,
//   - per-photo conflict resolution via `client_uuid` is straightforward.
//
// Owner-scoped from the start (post-Phase-11a). The hook
// `RegisterOwnerSetters` fills `owner` from the authenticated user.
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
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		userScopedRule := types.Pointer(
			"@request.auth.id != '' && owner = @request.auth.id",
		)
		authedCreateRule := types.Pointer("@request.auth.id != ''")

		samplePhotos := &models.Collection{
			Name: "sample_photos",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{
					Name:     "sample",
					Type:     schema.FieldTypeRelation,
					Required: true,
					Options: &schema.RelationOptions{
						CollectionId:  samples.Id,
						CascadeDelete: true, // sample-delete drops its photos
						MinSelect:     types.Pointer(1),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{
					Name:     "photo_file",
					Type:     schema.FieldTypeFile,
					Required: true,
					Options: &schema.FileOptions{
						MaxSelect: 1,
						MaxSize:   10 * 1024 * 1024,
						MimeTypes: []string{
							"image/jpeg",
							"image/png",
							"image/heic",
							"image/heif",
						},
					},
				},
				// Owner is filled by the create-hook (RegisterOwnerSetters).
				// Not marked Required — PocketBase validation runs before
				// the hook, same pattern as `samples.code`.
				&schema.SchemaField{
					Name: "owner",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  users.Id,
						CascadeDelete: true,
						MinSelect:     types.Pointer(0),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "client_uuid", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "client_updated_at", Type: schema.FieldTypeDate},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_sample_photos_sample ON sample_photos (sample)",
				"CREATE INDEX idx_sample_photos_owner ON sample_photos (owner)",
				"CREATE INDEX idx_sample_photos_client_uuid ON sample_photos (client_uuid)",
			},
			ListRule:   userScopedRule,
			ViewRule:   userScopedRule,
			CreateRule: authedCreateRule,
			UpdateRule: userScopedRule,
			DeleteRule: userScopedRule,
		}
		return dao.SaveCollection(samplePhotos)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		if c, err := dao.FindCollectionByNameOrId("sample_photos"); err == nil {
			return dao.DeleteCollection(c)
		}
		return nil
	})
}
