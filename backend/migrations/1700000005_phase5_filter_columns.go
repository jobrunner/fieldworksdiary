// Phase 5 — denormalised columns for fast filter queries on
// excursions.
//
//   - day_of_year (1..366): derived from collecting_day in the
//     user's TZ. Enables the cross-year seasonal filter
//     "alle Aufsammlungen 15.04.–15.05. über alle Jahre" without
//     a SQL DOY function (which SQLite doesn't have).
//   - country / admin_area: flat copies of admin_units.country
//     and admin_units.adminArea so queries don't have to JSON-path
//     into the blob.
//
// All three are written by the excursion-enrichment hook in
// `internal/enrichment/excursion.go`. Existing rows get a value the
// next time their excursion is re-enriched (i.e. on the next sample
// insert that touches that excursion).
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		coll.Schema.AddField(&schema.SchemaField{
			Name: "day_of_year", Type: schema.FieldTypeNumber,
		})
		coll.Schema.AddField(&schema.SchemaField{
			Name: "country", Type: schema.FieldTypeText,
		})
		coll.Schema.AddField(&schema.SchemaField{
			Name: "admin_area", Type: schema.FieldTypeText,
		})
		coll.Indexes = append(coll.Indexes,
			"CREATE INDEX idx_excursions_doy ON excursions (day_of_year)",
			"CREATE INDEX idx_excursions_country ON excursions (country)",
			"CREATE INDEX idx_excursions_admin_area ON excursions (admin_area)",
		)
		return dao.SaveCollection(coll)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		coll, err := dao.FindCollectionByNameOrId("excursions")
		if err != nil {
			return err
		}
		for _, fname := range []string{"day_of_year", "country", "admin_area"} {
			if f := coll.Schema.GetFieldByName(fname); f != nil {
				coll.Schema.RemoveField(f.Id)
			}
		}
		// Drop the indexes we appended. The migration only owns the
		// three at the tail of the array.
		newIndexes := make(types.JsonArray[string], 0, len(coll.Indexes))
		drop := map[string]bool{
			"CREATE INDEX idx_excursions_doy ON excursions (day_of_year)":         true,
			"CREATE INDEX idx_excursions_country ON excursions (country)":         true,
			"CREATE INDEX idx_excursions_admin_area ON excursions (admin_area)":   true,
		}
		for _, idx := range coll.Indexes {
			if !drop[idx] {
				newIndexes = append(newIndexes, idx)
			}
		}
		coll.Indexes = newIndexes
		return dao.SaveCollection(coll)
	})
}
