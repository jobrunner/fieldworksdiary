// Phase R6.1 — server-side locality fusion.
//
// Two schema changes:
//
//  1. `localities.needs_human_review` (Bool, default false). The
//     hook sets it to true when ServerFuse returns FlagAmbiguous
//     (≥ 2 neighbors inside the adaptive radius). The UI lists
//     flagged localities in a dedicated "möglicherweise Duplikate"
//     view (Spec §5.2 / §5.4).
//
//  2. New `locality_remap_events` collection. Whenever the hook
//     merges a duplicate into a target, it emits an event so every
//     client can re-hang its local sample rows from the old
//     locality id onto the new one. The event is idempotent on the
//     client side (apply twice = no-op, because the old id is
//     already gone after the first pass).
//
// Owner-scoping mirrors the rest of the user-facing collections.
// Writes are nil — only the backend hook may emit events.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		// 1. localities.needs_human_review
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		if localities.Fields.GetByName("needs_human_review") == nil {
			localities.Fields.Add(&core.BoolField{Name: "needs_human_review"})
			if err := app.Save(localities); err != nil {
				return err
			}
		}
		// Backfill: every existing row gets a `false` so the UI's
		// filter doesn't pick up NULLs.
		if _, err := app.DB().NewQuery(`
			UPDATE localities SET needs_human_review = 0
			WHERE needs_human_review IS NULL
		`).Execute(); err != nil {
			return err
		}

		// 2. locality_remap_events
		if c, err := app.FindCollectionByNameOrId("locality_remap_events"); err == nil && c != nil {
			return nil // idempotent: already exists
		}
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		ownerScope := types.Pointer("@request.auth.id != '' && owner = @request.auth.id")
		remap := newBaseCollection("locality_remap_events",
			&core.RelationField{
				Name:          "owner",
				Required:      true,
				CollectionId:  users.Id,
				CascadeDelete: true,
				MinSelect:     1,
				MaxSelect:     1,
			},
			&core.TextField{Name: "old_locality_id", Required: true},
			&core.TextField{Name: "new_locality_id", Required: true},
			&core.SelectField{
				Name:      "reason",
				Required:  true,
				Values:    []string{"merged_with_existing", "duplicate_cleanup"},
				MaxSelect: 1,
			},
			&core.JSONField{
				Name:    "affected_sample_ids",
				MaxSize: 256 * 1024, // 256 KiB — plenty for a merge of a few hundred samples
			},
		)
		remap.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_locality_remap_events_owner ON locality_remap_events (owner)",
			"CREATE INDEX idx_locality_remap_events_created ON locality_remap_events (created)",
			"CREATE INDEX idx_locality_remap_events_old ON locality_remap_events (old_locality_id)",
		}
		// Read: owner-scoped, so the client can poll its own
		// stream. Write: nil — only the backend hook emits.
		remap.ListRule = ownerScope
		remap.ViewRule = ownerScope
		return app.Save(remap)
	}, func(app core.App) error {
		if err := deleteCollectionIfExists(app, "locality_remap_events"); err != nil {
			return err
		}
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		if localities.Fields.GetByName("needs_human_review") != nil {
			removeFields(localities, "needs_human_review")
			return app.Save(localities)
		}
		return nil
	})
}
