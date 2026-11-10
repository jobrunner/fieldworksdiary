// Phase R2 (Refactor-Initiative) — rename the Excursion concept to
// Fieldtrip everywhere it touches the schema. Specifically:
//
//   - collection `excursions` → `fieldtrips`,
//   - FK field `samples.excursion` → `samples.fieldtrip`,
//   - bool field `fieldtrips.night_excursion` → `night_fieldtrip`,
//   - number field `users.default_excursion_split_km` →
//     `default_fieldtrip_split_km`,
//   - the SQL indexes on each of those.
//
// Domain glossary: a Fieldtrip is the bracket around a collecting
// day; the iOS UI keeps the German term "Exkursion" — only code
// identifiers change.
//
// PocketBase tracks collections by ID, so renaming a collection
// preserves all relation references. Field IDs are stable too —
// renaming a field keeps every stored value intact.
//
// Idempotent: a re-run finds the new names already present and
// skips each rename.
package migrations

import (
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		// 1. Rename collection `excursions` → `fieldtrips`, plus its
		//    own `night_excursion` field.
		if coll, err := app.FindCollectionByNameOrId("excursions"); err == nil && coll != nil {
			coll.Name = "fieldtrips"
			renameField(coll, "night_excursion", "night_fieldtrip")
			coll.Indexes = rewriteIndexes(coll.Indexes,
				"excursions", "fieldtrips",
				"idx_excursions_", "idx_fieldtrips_",
				"(night_excursion)", "(night_fieldtrip)",
			)
			if err := app.Save(coll); err != nil {
				return err
			}
		} else if coll, err := app.FindCollectionByNameOrId("fieldtrips"); err == nil && coll != nil {
			// Idempotent path: collection already renamed but a previous
			// run might have stopped before the inner field flip.
			if coll.Fields.GetByName("night_excursion") != nil {
				renameField(coll, "night_excursion", "night_fieldtrip")
				coll.Indexes = rewriteIndexes(coll.Indexes,
					"(night_excursion)", "(night_fieldtrip)",
				)
				if err := app.Save(coll); err != nil {
					return err
				}
			}
		}

		// 2. Rename field `samples.excursion` → `samples.fieldtrip`
		//    and the supporting index.
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		renameField(samples, "excursion", "fieldtrip")
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"(excursion)", "(fieldtrip)",
			"idx_samples_excursion", "idx_samples_fieldtrip",
		)
		if err := app.Save(samples); err != nil {
			return err
		}

		// 3. Rename `users.default_excursion_split_km` →
		//    `default_fieldtrip_split_km`. Pure DB-column rename;
		//    nothing in code reads this yet, but keeping naming
		//    consistent keeps Phase R3+ honest.
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if users.Fields.GetByName("default_excursion_split_km") != nil {
			renameField(users, "default_excursion_split_km", "default_fieldtrip_split_km")
			if err := app.Save(users); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		if coll, err := app.FindCollectionByNameOrId("fieldtrips"); err == nil && coll != nil {
			coll.Name = "excursions"
			renameField(coll, "night_fieldtrip", "night_excursion")
			coll.Indexes = rewriteIndexes(coll.Indexes,
				"fieldtrips", "excursions",
				"idx_fieldtrips_", "idx_excursions_",
				"(night_fieldtrip)", "(night_excursion)",
			)
			if err := app.Save(coll); err != nil {
				return err
			}
		}

		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		renameField(samples, "fieldtrip", "excursion")
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"(fieldtrip)", "(excursion)",
			"idx_samples_fieldtrip", "idx_samples_excursion",
		)
		if err := app.Save(samples); err != nil {
			return err
		}

		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if users.Fields.GetByName("default_fieldtrip_split_km") != nil {
			renameField(users, "default_fieldtrip_split_km", "default_excursion_split_km")
			if err := app.Save(users); err != nil {
				return err
			}
		}
		return nil
	})
}

// rewriteIndexes applies pairs of (old, new) substring substitutions
// to every index statement. Pairs are processed in order so callers
// can stage replacements (e.g. table name first, then index prefix).
func rewriteIndexes(in types.JSONArray[string], pairs ...string) types.JSONArray[string] {
	if len(pairs)%2 != 0 {
		panic("rewriteIndexes: pairs must come in twos")
	}
	out := make(types.JSONArray[string], 0, len(in))
	for _, stmt := range in {
		for i := 0; i < len(pairs); i += 2 {
			stmt = strings.ReplaceAll(stmt, pairs[i], pairs[i+1])
		}
		out = append(out, stmt)
	}
	return out
}
