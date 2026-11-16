// Phase 11a — flip every user-facing collection to `owner`-relation
// scoped by authenticated user.
//
//   - Replaces the dead `user_id` text field on samples, excursions
//     and sample_sequences with a real relation `owner → users`.
//   - Adds `owner → users` to localities, people, determinations,
//     label_pdfs (none of which had a user-link before).
//   - Updates indexes to use the owner column instead of user_id.
//   - Locks down rules to `@request.auth.id != ” && owner = @request.auth.id`
//     for the user-facing collections. `sample_sequences` and
//     `geocache` stay admin-only (server-internal).
//
// The owner field is NOT marked Required at the schema level. The
// create-hook fills it from the request context, but PocketBase
// validation runs before our hook (same pattern as Phase 1 `code`)
// — a required-field validator would reject every legit insert.
package migrations

import (
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		userScopedRule := types.Pointer(
			"@request.auth.id != '' && owner = @request.auth.id",
		)
		authedCreateRule := types.Pointer("@request.auth.id != ''")

		type plan struct {
			name           string
			addOwner       bool
			dropUserID     bool
			oldIndexNeedle string // legacy index substring to drop
			newOwnerIndex  string // CREATE INDEX statement to append
			scopedRules    bool   // apply user-scoped rules?
		}
		plans := []plan{
			{
				"samples", true, true,
				"idx_sample_sequences_user_day",
				"CREATE INDEX idx_samples_owner ON samples (owner)",
				true,
			},
			{
				"excursions", true, true,
				"idx_excursions_user_day",
				"CREATE INDEX idx_excursions_owner ON excursions (owner)",
				true,
			},
			{
				"localities", true, false, "",
				"CREATE INDEX idx_localities_owner ON localities (owner)",
				true,
			},
			{
				"people", true, false, "",
				"CREATE INDEX idx_people_owner ON people (owner)",
				true,
			},
			{
				"determinations", true, false, "",
				"CREATE INDEX idx_determinations_owner ON determinations (owner)",
				true,
			},
			{
				"label_pdfs", true, false, "",
				"CREATE INDEX idx_label_pdfs_owner ON label_pdfs (owner)",
				true,
			},
			{
				"sample_sequences", true, true, "",
				"CREATE UNIQUE INDEX idx_sample_sequences_owner_day ON sample_sequences (owner, collecting_day)",
				false,
			},
		}

		// On excursions the old user_id index included
		// collecting_day; we replace it with an owner-based one.
		// (samples has no collecting_day column — its `owner` index
		// alone covers the per-user filter we need.)
		extraReplacements := map[string]string{
			"excursions": "CREATE INDEX idx_excursions_owner_day ON excursions (owner, collecting_day)",
		}

		for _, p := range plans {
			coll, err := app.FindCollectionByNameOrId(p.name)
			if err != nil {
				return err
			}

			if p.addOwner {
				coll.Fields.Add(&core.RelationField{
					Name:          "owner",
					CollectionId:  users.Id,
					CascadeDelete: true, // user-delete cleans up
					MinSelect:     0,
					MaxSelect:     1,
				})
			}
			if p.dropUserID {
				removeFields(coll, "user_id")
			}

			// Index housekeeping — drop legacy ones referencing
			// user_id, append the new owner-based ones.
			coll.Indexes = filterIndexes(coll.Indexes, func(stmt string) bool {
				if strings.Contains(stmt, "user_id") {
					return false
				}
				if p.oldIndexNeedle != "" && strings.Contains(stmt, p.oldIndexNeedle) {
					return false
				}
				return true
			})
			coll.Indexes = append(coll.Indexes, p.newOwnerIndex)
			if extra, ok := extraReplacements[p.name]; ok {
				coll.Indexes = append(coll.Indexes, extra)
			}

			if p.scopedRules {
				coll.ListRule = userScopedRule
				coll.ViewRule = userScopedRule
				coll.CreateRule = authedCreateRule
				coll.UpdateRule = userScopedRule
				coll.DeleteRule = userScopedRule
			}

			if err := app.Save(coll); err != nil {
				return err
			}
		}

		return nil
	}, func(app core.App) error {
		// Down: restore the open rules + put back user_id (Text).
		// We deliberately don't re-create the legacy indexes — they
		// were unique and our owner-less dev data wouldn't satisfy
		// them on rollback.
		open := types.Pointer("")
		for _, name := range []string{
			"samples", "excursions", "localities", "people",
			"determinations", "label_pdfs", "sample_sequences",
		} {
			coll, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			removeFields(coll, "owner")
			if name == "samples" || name == "excursions" || name == "sample_sequences" {
				coll.Fields.Add(&core.TextField{Name: "user_id"})
			}
			coll.Indexes = filterIndexes(coll.Indexes, func(s string) bool {
				return !strings.Contains(s, "owner")
			})
			if name != "sample_sequences" {
				coll.ListRule = open
				coll.ViewRule = open
				coll.CreateRule = open
				coll.UpdateRule = open
				coll.DeleteRule = open
			}
			if err := app.Save(coll); err != nil {
				return err
			}
		}
		return nil
	})
}

func filterIndexes(in types.JSONArray[string], keep func(string) bool) types.JSONArray[string] {
	out := make(types.JSONArray[string], 0, len(in))
	for _, s := range in {
		if keep(s) {
			out = append(out, s)
		}
	}
	return out
}
