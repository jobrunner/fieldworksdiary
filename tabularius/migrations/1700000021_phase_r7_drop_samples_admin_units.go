// Phase R7.4 — drop the legacy `samples.admin_units` column.
//
// Pre-R3 the labelloc reverse-geocoding snapshot lived as a JSON blob
// on every sample. R7.1 moved reverse-geocoding onto Localities
// (the `placemarks` relation) and R7.3 backfilled the historical
// `samples.admin_units` snapshots into that table. After a week of
// Staging observation (Spec §6.1) the sample-side column is now dead
// weight: the only consumer that still needs the labelloc snapshot is
// the parent fieldtrip (NEW-2 keeps `fieldtrips.admin_units` as a
// denormalised filter snapshot), and the enricher now propagates the
// labelloc result straight to the fieldtrip without the sample
// intermediate (see internal/enrichment/enrichment.go).
//
// `fieldtrips.admin_units` stays untouched (NEW-2). Only the
// per-sample column goes.
//
// Down: re-create the column as an empty JSON field. The historical
// snapshots cannot be reconstructed from `placemarks` (that table is
// deduplicated and locality-scoped, not sample-scoped), so the down
// path is a best-effort empty schema restore, not a data restore.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Fields.GetByName("admin_units") != nil {
			removeFields(samples, "admin_units")
			return app.Save(samples)
		}
		// Already dropped — idempotent no-op.
		return nil
	}, func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Fields.GetByName("admin_units") != nil {
			return nil
		}
		samples.Fields.Add(&core.JSONField{
			Name:    "admin_units",
			MaxSize: 2 << 20, // 2 MiB, matches Phase 2
		})
		return app.Save(samples)
	})
}
