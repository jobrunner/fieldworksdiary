// Phase 14b — add `marked` boolean to samples.
//
// User-facing "star" / favourite flag. Defaults to false. Indexed so
// "show only marked" filters stay cheap even with thousands of rows.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		coll, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		coll.Fields.Add(&core.BoolField{Name: "marked"})
		coll.Indexes = append(coll.Indexes,
			"CREATE INDEX idx_samples_marked ON samples (marked)",
		)
		return app.Save(coll)
	}, func(app core.App) error {
		coll, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		removeFields(coll, "marked")
		coll.Indexes = filterIndexes(coll.Indexes, func(idx string) bool {
			return idx != "CREATE INDEX idx_samples_marked ON samples (marked)"
		})
		return app.Save(coll)
	})
}
