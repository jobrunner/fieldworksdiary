// Phase 6 — determinations and people.
//
// `people` is a tiny reference table (full_name, abbreviation for
// labels, optional email). `determinations` links a sample to a
// species_text + kind (det. / t. / vid.) + the person who made the
// call. Multiple determinations per sample are normal — the most
// recent det. wins, t./vid. are corroborating notes.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		open := types.Pointer("")

		// 1. people
		people := newBaseCollection("people",
			&core.TextField{Name: "full_name", Required: true},
			&core.TextField{Name: "abbreviation"},
			&core.EmailField{Name: "email"},
			&core.EditorField{Name: "notes"},
		)
		people.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_people_full_name ON people (full_name)",
		}
		people.ListRule = open
		people.ViewRule = open
		people.CreateRule = open
		people.UpdateRule = open
		people.DeleteRule = open
		if err := app.Save(people); err != nil {
			return err
		}

		// 2. determinations
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		determinations := newBaseCollection("determinations",
			&core.RelationField{
				Name:          "sample",
				Required:      true,
				CollectionId:  samples.Id,
				CascadeDelete: true, // determination dies with its sample
				MinSelect:     1,
				MaxSelect:     1,
			},
			&core.TextField{Name: "species_text", Required: true},
			&core.SelectField{
				Name:      "kind",
				Required:  true,
				Values:    []string{"det", "t", "vid"},
				MaxSelect: 1,
			},
			&core.RelationField{
				Name:          "person",
				CollectionId:  people.Id,
				CascadeDelete: false,
				MinSelect:     0,
				MaxSelect:     1,
			},
			&core.DateField{Name: "determined_on"},
			&core.TextField{Name: "notes"},
			&core.TextField{Name: "client_uuid"},
		)
		determinations.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_determinations_sample ON determinations (sample)",
			"CREATE INDEX idx_determinations_kind ON determinations (kind)",
			"CREATE INDEX idx_determinations_person ON determinations (person)",
		}
		determinations.ListRule = open
		determinations.ViewRule = open
		determinations.CreateRule = open
		determinations.UpdateRule = open
		determinations.DeleteRule = open
		return app.Save(determinations)
	}, func(app core.App) error {
		for _, name := range []string{"determinations", "people"} {
			if err := deleteCollectionIfExists(app, name); err != nil {
				return err
			}
		}
		return nil
	})
}
