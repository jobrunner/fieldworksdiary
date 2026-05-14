// Phase 2 — fields for async enrichment, plus geocache collection.
//
//   - samples / excursions get `admin_units` (labelloc snapshot),
//     `mtb` (sheet info + boundaries), `astro` (sun/moon, see §6.5)
//   - `geocache` is a write-through cache for external service
//     responses, keyed by (service, key) where key encodes the inputs
//     used for the lookup.
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

		jsonOpts := &schema.JsonOptions{MaxSize: 2 << 20} // 2 MiB

		// 1. Add admin_units, mtb, astro to samples and excursions.
		for _, name := range []string{"samples", "excursions"} {
			coll, err := dao.FindCollectionByNameOrId(name)
			if err != nil {
				return err
			}
			coll.Schema.AddField(&schema.SchemaField{
				Name: "admin_units", Type: schema.FieldTypeJson, Options: jsonOpts,
			})
			coll.Schema.AddField(&schema.SchemaField{
				Name: "mtb", Type: schema.FieldTypeJson, Options: jsonOpts,
			})
			if name == "excursions" {
				coll.Schema.AddField(&schema.SchemaField{
					Name: "astro", Type: schema.FieldTypeJson, Options: jsonOpts,
				})
			}
			if err := dao.SaveCollection(coll); err != nil {
				return err
			}
		}

		// 2. geocache  (server-only — not exposed to clients).
		geocache := &models.Collection{
			Name: "geocache",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "service", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "key", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "payload", Type: schema.FieldTypeJson, Required: true, Options: jsonOpts},
				&schema.SchemaField{Name: "cached_at", Type: schema.FieldTypeDate, Required: true},
			),
			Indexes: types.JsonArray[string]{
				"CREATE UNIQUE INDEX idx_geocache_service_key ON geocache (service, key)",
				"CREATE INDEX idx_geocache_cached_at ON geocache (cached_at)",
			},
			// no rules → admin-only (clients have no business reading
			// or writing the cache directly).
			ListRule:   nil,
			ViewRule:   nil,
			CreateRule: nil,
			UpdateRule: nil,
			DeleteRule: nil,
		}
		return dao.SaveCollection(geocache)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)

		if coll, err := dao.FindCollectionByNameOrId("geocache"); err == nil {
			if err := dao.DeleteCollection(coll); err != nil {
				return err
			}
		}
		for _, name := range []string{"samples", "excursions"} {
			coll, err := dao.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			for _, fname := range []string{"admin_units", "mtb", "astro"} {
				if f := coll.Schema.GetFieldByName(fname); f != nil {
					coll.Schema.RemoveField(f.Id)
				}
			}
			if err := dao.SaveCollection(coll); err != nil {
				return err
			}
		}
		return nil
	})
}
