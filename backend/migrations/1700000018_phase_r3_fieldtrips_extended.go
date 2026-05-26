// Phase R3.4 — fieldtrips picks up notes + version and the Spec
// field-name shape (`title`, `begin_date`, `end_date`).
//
// Why these specific renames? The Spec keeps Fieldtrip lean — a
// title and a date window — and pushes everything else (centroid,
// permit, astro, denormalised filter columns, mtb) into "carry-on"
// status. Per NEW-2, those carry-on columns stay where they are;
// they're already wired into UI and OpenAPI filters, and dropping
// them would be churn without payoff at this stage.
//
// Adds:
//   - notes (editor, optional)
//   - version (number, default 1)
//
// Renames:
//   - name → title
//   - started_at → begin_date
//   - ended_at → end_date
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
		fieldtrips, err := dao.FindCollectionByNameOrId("fieldtrips")
		if err != nil {
			return err
		}

		// Renames first (Field-IDs are stable, data + relations stay).
		renames := [][2]string{
			{"name", "title"},
			{"started_at", "begin_date"},
			{"ended_at", "end_date"},
		}
		for _, r := range renames {
			if f := fieldtrips.Schema.GetFieldByName(r[0]); f != nil {
				f.Name = r[1]
			}
		}

		addIfMissing := func(field *schema.SchemaField) {
			if fieldtrips.Schema.GetFieldByName(field.Name) == nil {
				fieldtrips.Schema.AddField(field)
			}
		}
		addIfMissing(&schema.SchemaField{Name: "notes", Type: schema.FieldTypeEditor})
		addIfMissing(&schema.SchemaField{Name: "version", Type: schema.FieldTypeNumber})

		if err := dao.SaveCollection(fieldtrips); err != nil {
			return err
		}

		// Default version = 1 for existing rows.
		if _, err := db.NewQuery(`
			UPDATE fieldtrips SET version = 1
			WHERE version IS NULL OR version = 0
		`).Execute(); err != nil {
			return err
		}
		return nil
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		fieldtrips, err := dao.FindCollectionByNameOrId("fieldtrips")
		if err != nil {
			return err
		}
		for _, name := range []string{"notes", "version"} {
			if f := fieldtrips.Schema.GetFieldByName(name); f != nil {
				fieldtrips.Schema.RemoveField(f.Id)
			}
		}
		renames := [][2]string{
			{"title", "name"},
			{"begin_date", "started_at"},
			{"end_date", "ended_at"},
		}
		for _, r := range renames {
			if f := fieldtrips.Schema.GetFieldByName(r[0]); f != nil {
				f.Name = r[1]
			}
		}
		return dao.SaveCollection(fieldtrips)
	})
}
