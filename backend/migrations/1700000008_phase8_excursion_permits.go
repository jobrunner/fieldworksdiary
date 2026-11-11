// Phase 8 — `permit_number` and `permit_pdf` on excursions.
//
// A research permit is per-excursion (or per-trip, but the unit of
// granting is the excursion). The number ends up on labels when set;
// the PDF lives on the record for archive purposes.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		coll, err := app.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		coll.Fields.Add(&core.TextField{Name: "permit_number"})
		coll.Fields.Add(&core.FileField{
			Name:      "permit_pdf",
			MaxSelect: 1,
			MaxSize:   20 * 1024 * 1024, // 20 MiB
			MimeTypes: []string{"application/pdf"},
		})
		return app.Save(coll)
	}, func(app core.App) error {
		coll, err := app.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		removeFields(coll, "permit_number", "permit_pdf")
		return app.Save(coll)
	})
}
