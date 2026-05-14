// Phase 8 — `permit_number` and `permit_pdf` on excursions.
//
// A research permit is per-excursion (or per-trip, but the unit of
// granting is the excursion). The number ends up on labels when set;
// the PDF lives on the record for archive purposes.
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
		coll, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		coll.Schema.AddField(&schema.SchemaField{
			Name: "permit_number", Type: schema.FieldTypeText,
		})
		coll.Schema.AddField(&schema.SchemaField{
			Name: "permit_pdf",
			Type: schema.FieldTypeFile,
			Options: &schema.FileOptions{
				MaxSelect: 1,
				MaxSize:   20 * 1024 * 1024, // 20 MiB
				MimeTypes: []string{"application/pdf"},
			},
		})
		return dao.SaveCollection(coll)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		for _, fname := range []string{"permit_number", "permit_pdf"} {
			if f := coll.Schema.GetFieldByName(fname); f != nil {
				coll.Schema.RemoveField(f.Id)
			}
		}
		return dao.SaveCollection(coll)
	})
}
