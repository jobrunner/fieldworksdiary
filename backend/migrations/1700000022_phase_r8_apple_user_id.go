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

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if users.Schema.GetFieldByName("apple_user_id") == nil {
			users.Schema.AddField(&schema.SchemaField{
				Name:    "apple_user_id",
				Type:    schema.FieldTypeText,
				Options: &schema.TextOptions{},
			})
		}
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
		return dao.SaveCollection(users)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if f := users.Schema.GetFieldByName("apple_user_id"); f != nil {
			users.Schema.RemoveField(f.Id)
		}
		users.Indexes = filterIndexes(users.Indexes, func(s string) bool {
			return !strings.Contains(s, "idx_users_apple_user_id")
		})
		return dao.SaveCollection(users)
	})
}
