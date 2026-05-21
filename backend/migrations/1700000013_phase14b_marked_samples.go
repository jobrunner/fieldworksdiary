// Phase 14b — add `marked` boolean to samples.
//
// User-facing "star" / favourite flag. Defaults to false. Indexed so
// "show only marked" filters stay cheap even with thousands of rows.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		coll.Schema.AddField(&schema.SchemaField{
			Name: "marked",
			Type: schema.FieldTypeBool,
		})
		coll.Indexes = append(coll.Indexes,
			"CREATE INDEX idx_samples_marked ON samples (marked)",
		)
		return dao.SaveCollection(coll)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if f := coll.Schema.GetFieldByName("marked"); f != nil {
			coll.Schema.RemoveField(f.Id)
		}
		filtered := coll.Indexes[:0]
		for _, idx := range coll.Indexes {
			if idx != "CREATE INDEX idx_samples_marked ON samples (marked)" {
				filtered = append(filtered, idx)
			}
		}
		coll.Indexes = filtered
		return dao.SaveCollection(coll)
	})
}
