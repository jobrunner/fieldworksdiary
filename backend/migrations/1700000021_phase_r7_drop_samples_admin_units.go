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
		if f := samples.Schema.GetFieldByName("admin_units"); f != nil {
			samples.Schema.RemoveField(f.Id)
			return dao.SaveCollection(samples)
		}
		// Already dropped — idempotent no-op.
		return nil
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Schema.GetFieldByName("admin_units") != nil {
			return nil
		}
		samples.Schema.AddField(&schema.SchemaField{
			Name:    "admin_units",
			Type:    schema.FieldTypeJson,
			Options: &schema.JsonOptions{MaxSize: 2 << 20}, // 2 MiB, matches Phase 2
		})
		return dao.SaveCollection(samples)
	})
}
