// Phase 11a — extend the built-in `users` auth collection.
//
// Domain fields (display_name, abbreviation, day_cutoff_hour,
// default_excursion_split_km, linked_person) replace the hardcoded
// constants we used in Phase 1. Auth options open up self-service
// registration via e-mail and password; OAuth2 is enabled at the
// collection level — actual Apple-OAuth2 provider keys are configured
// out-of-band via the PocketBase admin UI (Apple Service ID, Team ID,
// Key ID, Private Key).
//
// Rules:
//   - List: nil (admin-only — we don't expose a user list)
//   - View: only self
//   - Create: open (PocketBase enforces e-mail uniqueness + the
//     verification flow before granting access in higher-rules
//     collections later)
//   - Update / Delete: only self (so account deletion works without
//     admin intervention — App-Store-required)
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
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		// Auth options.
		if err := users.SetOptions(&models.CollectionAuthOptions{
			AllowEmailAuth:    true,
			AllowOAuth2Auth:   true,
			AllowUsernameAuth: false,
			RequireEmail:      true,
			MinPasswordLength: 8,
			OnlyVerified:      false, // verification is required for
			// some flows but we don't block login on it — many users
			// will register, log in, and then verify on the next
			// session via the mail link.
		}); err != nil {
			return err
		}

		// Domain fields. None are required so OAuth2 sign-ups (where
		// the iOS-side Apple credentials may or may not include the
		// full name) still go through cleanly.
		users.Schema.AddField(&schema.SchemaField{
			Name: "display_name", Type: schema.FieldTypeText,
		})
		users.Schema.AddField(&schema.SchemaField{
			Name: "abbreviation", Type: schema.FieldTypeText,
		})
		users.Schema.AddField(&schema.SchemaField{
			Name: "day_cutoff_hour",
			Type: schema.FieldTypeNumber,
			Options: &schema.NumberOptions{
				Min: floatPtr(0),
				Max: floatPtr(23),
			},
		})
		users.Schema.AddField(&schema.SchemaField{
			Name: "default_excursion_split_km",
			Type: schema.FieldTypeNumber,
			Options: &schema.NumberOptions{
				Min: floatPtr(0),
			},
		})

		// linked_person needs the people collection to exist already
		// (Phase 6). If we ever migrate from a fresh DB without
		// people, we tolerate the lookup failing.
		if people, err := dao.FindCollectionByNameOrId("people"); err == nil {
			users.Schema.AddField(&schema.SchemaField{
				Name: "linked_person",
				Type: schema.FieldTypeRelation,
				Options: &schema.RelationOptions{
					CollectionId:  people.Id,
					CascadeDelete: false,
					MinSelect:     types.Pointer(0),
					MaxSelect:     types.Pointer(1),
				},
			})
		}

		users.ListRule = nil
		users.ViewRule = types.Pointer("id = @request.auth.id")
		users.CreateRule = types.Pointer("")
		users.UpdateRule = types.Pointer("id = @request.auth.id")
		users.DeleteRule = types.Pointer("id = @request.auth.id")

		return dao.SaveCollection(users)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		users, err := dao.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		for _, fname := range []string{
			"display_name", "abbreviation", "day_cutoff_hour",
			"default_excursion_split_km", "linked_person",
		} {
			if f := users.Schema.GetFieldByName(fname); f != nil {
				users.Schema.RemoveField(f.Id)
			}
		}
		// Reset auth options to PocketBase defaults.
		_ = users.SetOptions(&models.CollectionAuthOptions{
			AllowEmailAuth:    true,
			AllowOAuth2Auth:   true,
			AllowUsernameAuth: true,
			MinPasswordLength: 8,
		})
		users.ListRule = nil
		users.ViewRule = nil
		users.CreateRule = nil
		users.UpdateRule = nil
		users.DeleteRule = nil
		return dao.SaveCollection(users)
	})
}

func floatPtr(f float64) *float64 { return &f }
