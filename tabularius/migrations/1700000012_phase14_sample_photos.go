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
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		userScopedRule := types.Pointer(
			"@request.auth.id != '' && owner = @request.auth.id",
		)
		authedCreateRule := types.Pointer("@request.auth.id != ''")

		samplePhotos := newBaseCollection("sample_photos",
			&core.RelationField{
				Name:          "sample",
				Required:      true,
				CollectionId:  samples.Id,
				CascadeDelete: true, // sample-delete drops its photos
				MinSelect:     1,
				MaxSelect:     1,
			},
			&core.FileField{
				Name:      "photo_file",
				Required:  true,
				MaxSelect: 1,
				MaxSize:   10 * 1024 * 1024,
				MimeTypes: []string{
					"image/jpeg",
					"image/png",
					"image/heic",
					"image/heif",
				},
			},
			// Owner is filled by the create-hook (RegisterOwnerSetters).
			// Not marked Required — same pattern as `samples.code`.
			&core.RelationField{
				Name:          "owner",
				CollectionId:  users.Id,
				CascadeDelete: true,
				MinSelect:     0,
				MaxSelect:     1,
			},
			&core.TextField{Name: "client_uuid"},
			&core.DateField{Name: "client_updated_at"},
		)
		samplePhotos.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_sample_photos_sample ON sample_photos (sample)",
			"CREATE INDEX idx_sample_photos_owner ON sample_photos (owner)",
			"CREATE INDEX idx_sample_photos_client_uuid ON sample_photos (client_uuid)",
		}
		samplePhotos.ListRule = userScopedRule
		samplePhotos.ViewRule = userScopedRule
		samplePhotos.CreateRule = authedCreateRule
		samplePhotos.UpdateRule = userScopedRule
		samplePhotos.DeleteRule = userScopedRule
		return app.Save(samplePhotos)
	}, func(app core.App) error {
		return deleteCollectionIfExists(app, "sample_photos")
	})
}
