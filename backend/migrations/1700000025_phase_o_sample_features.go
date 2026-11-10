// Phase O.3 — `sample_features`: external geo features (protected areas,
// habitats, …) attached to a sample, with source and license info.
// Owner-scoped read; writes are backend-only.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		if c, err := app.FindCollectionByNameOrId("sample_features"); err == nil && c != nil {
			return nil
		}
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		rule := types.Pointer("@request.auth.id != '' && owner = @request.auth.id")
		c := newBaseCollection("sample_features",
			&core.RelationField{
				Name: "owner", Required: true,
				CollectionId: users.Id,
				MinSelect:    1,
				MaxSelect:    1,
			},
			&core.RelationField{
				Name: "sample", Required: true,
				CollectionId:  samples.Id,
				CascadeDelete: true,
				MinSelect:     1,
				MaxSelect:     1,
			},
			&core.TextField{Name: "source_id"},
			&core.TextField{Name: "source_name"},
			&core.TextField{Name: "layer"},
			&core.TextField{Name: "feature_id"},
			&core.JSONField{Name: "properties", MaxSize: 2 << 20},
			&core.JSONField{Name: "license", MaxSize: 2 << 20},
			&core.DateField{Name: "fetched_at"},
		)
		c.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_sample_features_sample_source ON sample_features (sample, source_id)",
		}
		c.ListRule = rule
		c.ViewRule = rule
		return app.Save(c)
	}, func(app core.App) error {
		return deleteCollectionIfExists(app, "sample_features")
	})
}
