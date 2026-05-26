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
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)

		// 1. localities.needs_human_review
		localities, err := dao.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		if localities.Schema.GetFieldByName("needs_human_review") == nil {
			localities.Schema.AddField(&schema.SchemaField{
				Name: "needs_human_review",
				Type: schema.FieldTypeBool,
			})
			if err := dao.SaveCollection(localities); err != nil {
				return err
			}
		}
		// Backfill: every existing row gets a `false` so the UI's
		// filter doesn't pick up NULLs.
		if _, err := db.NewQuery(`
			UPDATE localities SET needs_human_review = 0
			WHERE needs_human_review IS NULL
		`).Execute(); err != nil {
			return err
		}

		// 2. locality_remap_events
		if c, err := dao.FindCollectionByNameOrId("locality_remap_events"); err == nil && c != nil {
			return nil // idempotent: already exists
		}
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		ownerScope := types.Pointer("@request.auth.id != '' && owner = @request.auth.id")
		remap := &models.Collection{
			Name: "locality_remap_events",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{
					Name:     "owner",
					Type:     schema.FieldTypeRelation,
					Required: true,
					Options: &schema.RelationOptions{
						CollectionId:  users.Id,
						CascadeDelete: true,
						MinSelect:     types.Pointer(1),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{
					Name:     "old_locality_id",
					Type:     schema.FieldTypeText,
					Required: true,
				},
				&schema.SchemaField{
					Name:     "new_locality_id",
					Type:     schema.FieldTypeText,
					Required: true,
				},
				&schema.SchemaField{
					Name:     "reason",
					Type:     schema.FieldTypeSelect,
					Required: true,
					Options: &schema.SelectOptions{
						Values:    []string{"merged_with_existing", "duplicate_cleanup"},
						MaxSelect: 1,
					},
				},
				&schema.SchemaField{
					Name: "affected_sample_ids",
					Type: schema.FieldTypeJson,
					Options: &schema.JsonOptions{
						MaxSize: 256 * 1024, // 256 KiB — plenty for a merge of a few hundred samples
					},
				},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_locality_remap_events_owner ON locality_remap_events (owner)",
				"CREATE INDEX idx_locality_remap_events_created ON locality_remap_events (created)",
				"CREATE INDEX idx_locality_remap_events_old ON locality_remap_events (old_locality_id)",
			},
			// Read: owner-scoped, so the client can poll its own
			// stream. Write: nil — only the backend hook emits.
			ListRule:   ownerScope,
			ViewRule:   ownerScope,
			CreateRule: nil,
			UpdateRule: nil,
			DeleteRule: nil,
		}
		return dao.SaveCollection(remap)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		if c, err := dao.FindCollectionByNameOrId("locality_remap_events"); err == nil && c != nil {
			if err := dao.DeleteCollection(c); err != nil {
				return err
			}
		}
		localities, err := dao.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		if f := localities.Schema.GetFieldByName("needs_human_review"); f != nil {
			localities.Schema.RemoveField(f.Id)
			return dao.SaveCollection(localities)
		}
		return nil
	})
}
