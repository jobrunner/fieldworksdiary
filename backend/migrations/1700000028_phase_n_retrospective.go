// Phase N — nachgetragene Samples.
//
//   - samples: is_retrospective (bool, default false). Set once at
//     create time by the client; the update hook never lets it flip.
//
// Down removes the field again.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Fields.GetByName("is_retrospective") != nil {
			return nil
		}
		samples.Fields.Add(&core.BoolField{Name: "is_retrospective"})
		return app.Save(samples)
	}, func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}
		if samples.Fields.GetByName("is_retrospective") != nil {
			removeFields(samples, "is_retrospective")
			return app.Save(samples)
		}
		return nil
	})
}
