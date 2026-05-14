// Phase 3b — drop the UNIQUE constraint from samples.code.
//
// Reason: PocketBase derives form-level uniqueness validators from a
// collection's `Indexes` JSON. A UNIQUE INDEX therefore short-circuits
// our create hook — the validator rejects a client-supplied code that
// collides BEFORE the hook gets to reassign it. We still want a code
// index for query performance, just not the auto-validator.
//
// Uniqueness is now enforced exclusively by the hook in
// internal/hooks/sample_create.go, inside the transaction that does
// the insert. SQLite's write serialisation keeps the check race-free
// for the single-device-single-user pattern we live in.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		coll.Indexes = types.JsonArray[string]{
			"CREATE INDEX idx_samples_code ON samples (code)",
			"CREATE INDEX idx_samples_excursion ON samples (excursion)",
		}
		return dao.SaveCollection(coll)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		coll.Indexes = types.JsonArray[string]{
			"CREATE UNIQUE INDEX idx_samples_code ON samples (code)",
			"CREATE INDEX idx_samples_excursion ON samples (excursion)",
		}
		return dao.SaveCollection(coll)
	})
}
