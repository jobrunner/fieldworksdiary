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

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)

		// 1. Rename collection `excursions` → `fieldtrips`, plus its
		//    own `night_excursion` field.
		if coll, err := dao.FindCollectionByNameOrId("excursions"); err == nil && coll != nil {
			coll.Name = "fieldtrips"
			if f := coll.Schema.GetFieldByName("night_excursion"); f != nil {
				f.Name = "night_fieldtrip"
			}
			coll.Indexes = rewriteIndexes(coll.Indexes,
				"excursions", "fieldtrips",
				"idx_excursions_", "idx_fieldtrips_",
				"(night_excursion)", "(night_fieldtrip)",
			)
			if err := dao.SaveCollection(coll); err != nil {
				return err
			}
		} else if coll, err := dao.FindCollectionByNameOrId("fieldtrips"); err == nil && coll != nil {
			// Idempotent path: collection already renamed but a previous
			// run might have stopped before the inner field flip.
			if f := coll.Schema.GetFieldByName("night_excursion"); f != nil {
				f.Name = "night_fieldtrip"
				coll.Indexes = rewriteIndexes(coll.Indexes,
					"(night_excursion)", "(night_fieldtrip)",
				)
				if err := dao.SaveCollection(coll); err != nil {
					return err
				}
			}
		}

		// 2. Rename field `samples.excursion` → `samples.fieldtrip`
		//    and the supporting index.
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if f := samples.Schema.GetFieldByName("excursion"); f != nil {
			f.Name = "fieldtrip"
		}
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"(excursion)", "(fieldtrip)",
			"idx_samples_excursion", "idx_samples_fieldtrip",
		)
		if err := dao.SaveCollection(samples); err != nil {
			return err
		}

		// 3. Rename `users.default_excursion_split_km` →
		//    `default_fieldtrip_split_km`. Pure DB-column rename;
		//    nothing in code reads this yet, but keeping naming
		//    consistent keeps Phase R3+ honest.
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if f := users.Schema.GetFieldByName("default_excursion_split_km"); f != nil {
			f.Name = "default_fieldtrip_split_km"
			if err := dao.SaveCollection(users); err != nil {
				return err
			}
		}
		return nil
	}, func(db dbx.Builder) error {
		dao := daos.New(db)

		if coll, err := dao.FindCollectionByNameOrId("fieldtrips"); err == nil && coll != nil {
			coll.Name = "excursions"
			if f := coll.Schema.GetFieldByName("night_fieldtrip"); f != nil {
				f.Name = "night_excursion"
			}
			coll.Indexes = rewriteIndexes(coll.Indexes,
				"fieldtrips", "excursions",
				"idx_fieldtrips_", "idx_excursions_",
				"(night_fieldtrip)", "(night_excursion)",
			)
			if err := dao.SaveCollection(coll); err != nil {
				return err
			}
		}

		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if f := samples.Schema.GetFieldByName("fieldtrip"); f != nil {
			f.Name = "excursion"
		}
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"(fieldtrip)", "(excursion)",
			"idx_samples_fieldtrip", "idx_samples_excursion",
		)
		if err := dao.SaveCollection(samples); err != nil {
			return err
		}

		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if f := users.Schema.GetFieldByName("default_fieldtrip_split_km"); f != nil {
			f.Name = "default_excursion_split_km"
			if err := dao.SaveCollection(users); err != nil {
				return err
			}
		}
		return nil
	})
}

// rewriteIndexes applies pairs of (old, new) substring substitutions
// to every index statement. Pairs are processed in order so callers
// can stage replacements (e.g. table name first, then index prefix).
func rewriteIndexes(in types.JsonArray[string], pairs ...string) types.JsonArray[string] {
	if len(pairs)%2 != 0 {
		panic("rewriteIndexes: pairs must come in twos")
	}
	out := make(types.JsonArray[string], 0, len(in))
	for _, stmt := range in {
		for i := 0; i < len(pairs); i += 2 {
			stmt = strings.ReplaceAll(stmt, pairs[i], pairs[i+1])
		}
		out = append(out, stmt)
	}
	return out
}
