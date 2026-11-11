// Phase R8 — native Sign in with Apple support: stable per-app Apple
// user id (`sub` claim) lives on the `users` record so repeat logins
// from the same Apple user always resolve to the same PB user.
//
// Apple's `sub` is unique per (Team, Apple-user) — stable across
// devices and reinstalls — so it's the right key to look up by. The
// column is optional (email/password users don't have one) and
// uniquely indexed when present.
package migrations

import (
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		addFieldIfMissing(users, &core.TextField{Name: "apple_user_id"})
		// Sparse unique index — empty strings (the bulk of legacy rows)
		// are allowed to collide; only set values must be unique.
		const idxName = "idx_users_apple_user_id"
		has := false
		for _, stmt := range users.Indexes {
			if strings.Contains(stmt, idxName) {
				has = true
				break
			}
		}
		if !has {
			users.Indexes = append(users.Indexes,
				"CREATE UNIQUE INDEX "+idxName+" ON users (apple_user_id) "+
					"WHERE apple_user_id IS NOT NULL AND apple_user_id != ''",
			)
		}
		return app.Save(users)
	}, func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		removeFields(users, "apple_user_id")
		users.Indexes = filterIndexes(users.Indexes, func(s string) bool {
			return !strings.Contains(s, "idx_users_apple_user_id")
		})
		return app.Save(users)
	})
}
