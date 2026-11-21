// Phase S — idempotente Proben-Anlage.
//
// Unique index on samples (owner, client_uuid) for non-empty uuids: a
// repeated create (timeout, retry, two sync runners) must not store a
// sample twice, also when the first request is still running.
// Duplicates from before the index stay as they are — they are real
// rows the user may have edited; the later rows lose their uuid so the
// index can be created. Nothing is deleted or merged.
//
// Down drops the index. The cleared uuids are not restored.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// sampleUUIDIndexName makes (owner, client_uuid) unique for samples that
// carry a uuid.
const sampleUUIDIndexName = "idx_samples_owner_client_uuid_unique"

func sampleUUIDUniqueUp(app core.App) error {
	// Keep the oldest row of every duplicate group as the holder of the
	// uuid.
	if _, err := app.DB().NewQuery(`UPDATE samples SET client_uuid = ''
		WHERE client_uuid != '' AND rowid NOT IN (
			SELECT MIN(rowid) FROM samples WHERE client_uuid != '' GROUP BY owner, client_uuid
		)`).Execute(); err != nil {
		return err
	}
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	coll.AddIndex(sampleUUIDIndexName, true, "owner, client_uuid", "client_uuid != ''")
	return app.Save(coll)
}

func sampleUUIDUniqueDown(app core.App) error {
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	coll.RemoveIndex(sampleUUIDIndexName)
	return app.Save(coll)
}

func init() {
	m.Register(sampleUUIDUniqueUp, sampleUUIDUniqueDown)
}
