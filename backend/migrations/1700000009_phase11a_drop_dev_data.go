// Phase 11a — drop every user-facing record from the dev/test era.
//
// We're about to flip the data model from "user_id is a text field
// that's always 'default'" to "owner is a relation to a real
// authenticated user". Existing dev rows have no real owner; rather
// than backfilling them to some placeholder account we just wipe.
// The user confirmed this is fine (test data only).
//
// `geocache` is wiped too — its cache keys are fine but the records
// belong to a clean-slate session anyway.
package migrations

import (
	"github.com/pocketbase/dbx"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		// Order matters: child tables before parents to keep
		// the FK-light Pocketbase relations happy on rollback. In
		// practice PB uses cascade or no-cascade per field setting;
		// we don't have hard FKs at SQL level, but the order keeps
		// dependent data clean for any human inspection.
		for _, table := range []string{
			"label_pdfs",
			"determinations",
			"samples",
			"excursions",
			"sample_sequences",
			"localities",
			"people",
			"geocache",
		} {
			if _, err := db.NewQuery("DELETE FROM " + table).Execute(); err != nil {
				return err
			}
		}
		return nil
	}, func(db dbx.Builder) error {
		// Down is a no-op — we can't synthesize back the dev data
		// we just dropped. Re-running fresh migrations gets the
		// empty schema you expect.
		return nil
	})
}
