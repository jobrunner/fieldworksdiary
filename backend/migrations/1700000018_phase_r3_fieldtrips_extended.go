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
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		fieldtrips, err := app.FindCollectionByNameOrId("fieldtrips")
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
			renameField(fieldtrips, r[0], r[1])
		}

		addFieldIfMissing(fieldtrips, &core.EditorField{Name: "notes"})
		addFieldIfMissing(fieldtrips, &core.NumberField{Name: "version"})

		if err := app.Save(fieldtrips); err != nil {
			return err
		}

		// Default version = 1 for existing rows.
		if _, err := app.DB().NewQuery(`
			UPDATE fieldtrips SET version = 1
			WHERE version IS NULL OR version = 0
		`).Execute(); err != nil {
			return err
		}
		return nil
	}, func(app core.App) error {
		fieldtrips, err := app.FindCollectionByNameOrId("fieldtrips")
		if err != nil {
			return err
		}
		removeFields(fieldtrips, "notes", "version")
		renames := [][2]string{
			{"title", "name"},
			{"begin_date", "started_at"},
			{"end_date", "ended_at"},
		}
		for _, r := range renames {
			renameField(fieldtrips, r[0], r[1])
		}
		return app.Save(fieldtrips)
	})
}
