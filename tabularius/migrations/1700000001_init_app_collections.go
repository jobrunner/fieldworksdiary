// Phase 1 — initial collections: localities, excursions, samples,
// sample_sequences. Rules are wide open ("" = anyone, including
// unauthenticated) for the dev bootstrap; auth is wired in a later
// phase.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		open := types.Pointer("")

		// 1. localities
		localities := newBaseCollection("localities",
			&core.TextField{Name: "name", Required: true},
			&core.NumberField{Name: "centroid_lat"},
			&core.NumberField{Name: "centroid_lon"},
			&core.NumberField{Name: "radius_m"},
			&core.EditorField{Name: "notes"},
		)
		localities.ListRule = open
		localities.ViewRule = open
		localities.CreateRule = open
		localities.UpdateRule = open
		localities.DeleteRule = open
		if err := app.Save(localities); err != nil {
			return err
		}

		// 2. excursions  (relation → localities)
		//
		// user_id, started_at, ended_at, collecting_day are populated
		// by the sample-create hook, never by the client. Schema-level
		// `Required` is therefore off — the hook is the single source
		// of truth, and PocketBase validation runs *before* the hook
		// so requiring them here would just reject every legit insert.
		excursions := newBaseCollection("excursions",
			&core.TextField{Name: "name"},
			&core.TextField{Name: "user_id"},
			&core.DateField{Name: "started_at"},
			&core.DateField{Name: "ended_at"},
			// collecting_day stored as YYYY-MM-DD (PocketBase has no
			// date-only type; using text keeps the value uniform
			// across SQLite and JSON).
			&core.TextField{Name: "collecting_day"},
			&core.BoolField{Name: "night_excursion"},
			&core.NumberField{Name: "centroid_lat"},
			&core.NumberField{Name: "centroid_lon"},
			&core.RelationField{
				Name:          "locality",
				CollectionId:  localities.Id,
				CascadeDelete: false,
				MinSelect:     0,
				MaxSelect:     1,
			},
			&core.TextField{Name: "client_uuid"},
			&core.DateField{Name: "client_updated_at"},
		)
		excursions.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_excursions_user_day ON excursions (user_id, collecting_day)",
		}
		excursions.ListRule = open
		excursions.ViewRule = open
		excursions.CreateRule = open
		excursions.UpdateRule = open
		excursions.DeleteRule = open
		if err := app.Save(excursions); err != nil {
			return err
		}

		// 3. samples  (relation → excursions)
		//
		// `code`, `excursion`, `user_id` are filled by the
		// before-create hook; not Required at schema level (see
		// note on excursions). `lat` / `lon` come from the client.
		samples := newBaseCollection("samples",
			&core.TextField{Name: "code"},
			&core.TextField{Name: "original_code"},
			&core.RelationField{
				Name:          "excursion",
				CollectionId:  excursions.Id,
				CascadeDelete: false,
				MinSelect:     0,
				MaxSelect:     1,
			},
			&core.TextField{Name: "user_id"},
			&core.DateField{Name: "collected_from"},
			&core.DateField{Name: "collected_to"},
			&core.NumberField{Name: "lat", Required: true},
			&core.NumberField{Name: "lon", Required: true},
			&core.NumberField{Name: "altitude_m"},
			&core.NumberField{Name: "accuracy_m"},
			&core.EditorField{Name: "notes"},
			&core.TextField{Name: "client_uuid"},
			&core.DateField{Name: "client_updated_at"},
		)
		samples.Indexes = types.JSONArray[string]{
			"CREATE UNIQUE INDEX idx_samples_code ON samples (code)",
			"CREATE INDEX idx_samples_excursion ON samples (excursion)",
		}
		samples.ListRule = open
		samples.ViewRule = open
		samples.CreateRule = open
		samples.UpdateRule = open
		samples.DeleteRule = open
		if err := app.Save(samples); err != nil {
			return err
		}

		// 4. sample_sequences  (atomic counter per user × collecting_day)
		//
		// sequence rows are written exclusively by the server-side
		// hook; clients have no business touching them (nil rules).
		sequences := newBaseCollection("sample_sequences",
			&core.TextField{Name: "user_id", Required: true},
			&core.TextField{Name: "collecting_day", Required: true},
			&core.NumberField{Name: "last_seq", Required: true},
		)
		sequences.Indexes = types.JSONArray[string]{
			"CREATE UNIQUE INDEX idx_sample_sequences_user_day ON sample_sequences (user_id, collecting_day)",
		}
		return app.Save(sequences)
	}, func(app core.App) error {
		// reverse order — samples and sample_sequences first, then
		// excursions, then localities.
		for _, name := range []string{"samples", "sample_sequences", "excursions", "localities"} {
			if err := deleteCollectionIfExists(app, name); err != nil {
				return err
			}
		}
		return nil
	})
}
