// Phase N — nachgetragene Samples.
//
//   - samples: is_retrospective (bool, default false). Set once at
//     create time by the client; the update hook never lets it flip.
//
// Down removes the field again.
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
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Schema.GetFieldByName("is_retrospective") != nil {
			return nil
		}
		samples.Schema.AddField(&schema.SchemaField{
			Name: "is_retrospective",
			Type: schema.FieldTypeBool,
		})
		return dao.SaveCollection(samples)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if f := samples.Schema.GetFieldByName("is_retrospective"); f != nil {
			samples.Schema.RemoveField(f.Id)
			return dao.SaveCollection(samples)
		}
		return nil
	})
}
