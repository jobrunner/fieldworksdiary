// Phase R3.3 — samples schema goes Spec-aligned.
//
// Two kinds of change in one migration:
//
//  1. New columns:
//     - is_all_day (bool, default false)
//     - time_zone (text, default "Europe/Berlin", IANA identifier)
//     - version (number, default 1) — monotone sync counter
//     - location_source (select: user|location_service|sample|locality)
//     - vertical_accuracy (number)
//     - locality (relation → localities, single, optional)
//
//  2. Field renames (Spec §2):
//     - code → sample_id
//     - collected_from → begin_date
//     - collected_to → end_date
//     - lat → latitude
//     - lon → longitude
//     - accuracy_m → horizontal_accuracy
//     - altitude_m → altitude
//
// Also: `latitude`/`longitude` flip from required → optional (Spec
// 1.2). The schema-level required flag is dropped; the create
// flow can still validate "must have a coordinate" at the use-case
// level (UI flow), without breaking nachträglich-eingetragene
// samples that arrive without a coordinate.
//
// Index changes:
//   - `idx_samples_code` is renamed to `idx_samples_sample_id`
//     (still non-unique — the create hook is the single source of
//     truth for code uniqueness, see Migration 3 for the why).
//     A composite `(owner, sample_id)` index is added for the
//     per-user lookup pattern the Spec asks for; we deliberately
//     **don't** mark it UNIQUE: PocketBase would derive a
//     form-level validator from a UNIQUE index and reject a
//     client-supplied colliding code before the hook can reassign
//     it (same problem Phase 3b fixed).
//
// Backfill:
//   - location_source = "user" for legacy rows (Spec §8 heuristic
//     "no accuracy ⇒ user"; we go with "user" as the safe default
//     since the older rows predate the source concept entirely).
//   - version = 1 across the board.
//   - time_zone = "Europe/Berlin" for legacy rows.
package migrations

import (
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}

		// 1. Renames — preserve field IDs so data + relations stick.
		renames := [][2]string{
			{"code", "sample_id"},
			{"collected_from", "begin_date"},
			{"collected_to", "end_date"},
			{"lat", "latitude"},
			{"lon", "longitude"},
			{"accuracy_m", "horizontal_accuracy"},
			{"altitude_m", "altitude"},
		}
		for _, r := range renames {
			renameField(samples, r[0], r[1])
		}

		// 2. latitude/longitude optional (drop required flag).
		for _, name := range []string{"latitude", "longitude"} {
			if f, ok := samples.Fields.GetByName(name).(*core.NumberField); ok {
				f.Required = false
			}
		}

		// 3. New columns.
		addFieldIfMissing(samples, &core.BoolField{Name: "is_all_day"})
		addFieldIfMissing(samples, &core.TextField{Name: "time_zone"})
		addFieldIfMissing(samples, &core.NumberField{Name: "version"})
		addFieldIfMissing(samples, &core.SelectField{
			Name:      "location_source",
			Values:    []string{"user", "location_service", "sample", "locality"},
			MaxSelect: 1,
		})
		addFieldIfMissing(samples, &core.NumberField{Name: "vertical_accuracy"})
		addFieldIfMissing(samples, &core.RelationField{
			Name:          "locality",
			CollectionId:  localities.Id,
			CascadeDelete: false,
			MinSelect:     0,
			MaxSelect:     1,
		})

		// 4. Indexes.
		//    - Rewrite idx_samples_code → idx_samples_sample_id (the
		//      column rename above doesn't propagate to the index DDL
		//      that PocketBase persists as JSON).
		//    - Add composite (owner, sample_id) for per-user lookups.
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"idx_samples_code", "idx_samples_sample_id",
			"(code)", "(sample_id)",
		)
		hasComposite := false
		for _, stmt := range samples.Indexes {
			if strings.Contains(stmt, "idx_samples_owner_sample_id") {
				hasComposite = true
				break
			}
		}
		if !hasComposite {
			samples.Indexes = append(samples.Indexes,
				"CREATE INDEX idx_samples_owner_sample_id ON samples (owner, sample_id)")
		}

		if err := app.Save(samples); err != nil {
			return err
		}

		// 5. Backfill — raw SQL, single round-trip per column.
		queries := []string{
			`UPDATE samples SET location_source = 'user'
			 WHERE location_source IS NULL OR location_source = ''`,
			`UPDATE samples SET version = 1
			 WHERE version IS NULL OR version = 0`,
			`UPDATE samples SET time_zone = 'Europe/Berlin'
			 WHERE time_zone IS NULL OR time_zone = ''`,
			`UPDATE samples SET is_all_day = 0
			 WHERE is_all_day IS NULL`,
		}
		for _, q := range queries {
			if _, err := app.DB().NewQuery(q).Execute(); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		// Drop the new columns first, then unwind the renames so the
		// resulting schema matches what migrations 1–14 + R2 produced.
		removeFields(samples,
			"is_all_day", "time_zone", "version",
			"location_source", "vertical_accuracy", "locality",
		)
		renames := [][2]string{
			{"sample_id", "code"},
			{"begin_date", "collected_from"},
			{"end_date", "collected_to"},
			{"latitude", "lat"},
			{"longitude", "lon"},
			{"horizontal_accuracy", "accuracy_m"},
			{"altitude", "altitude_m"},
		}
		for _, r := range renames {
			renameField(samples, r[0], r[1])
		}
		for _, name := range []string{"lat", "lon"} {
			if f, ok := samples.Fields.GetByName(name).(*core.NumberField); ok {
				f.Required = true
			}
		}
		samples.Indexes = rewriteIndexes(samples.Indexes,
			"idx_samples_sample_id", "idx_samples_code",
			"(sample_id)", "(code)",
		)
		samples.Indexes = filterIndexes(samples.Indexes, func(s string) bool {
			return !strings.Contains(s, "idx_samples_owner_sample_id")
		})
		return app.Save(samples)
	})
}
