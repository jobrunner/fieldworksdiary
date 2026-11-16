// Phase 2 — fields for async enrichment, plus geocache collection.
//
//   - samples / excursions get `admin_units` (labelloc snapshot),
//     `mtb` (sheet info + boundaries), `astro` (sun/moon, see §6.5)
//   - `geocache` is a write-through cache for external service
//     responses, keyed by (service, key) where key encodes the inputs
//     used for the lookup.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		const jsonMax = 2 << 20 // 2 MiB

		// 1. Add admin_units, mtb, astro to samples and excursions.
		for _, name := range []string{"samples", "excursions"} {
			coll, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				return err
			}
			coll.Fields.Add(&core.JSONField{Name: "admin_units", MaxSize: jsonMax})
			coll.Fields.Add(&core.JSONField{Name: "mtb", MaxSize: jsonMax})
			if name == "excursions" {
				coll.Fields.Add(&core.JSONField{Name: "astro", MaxSize: jsonMax})
			}
			if err := app.Save(coll); err != nil {
				return err
			}
		}

		// 2. geocache  (server-only — not exposed to clients).
		//
		// no rules → superuser-only (clients have no business reading
		// or writing the cache directly).
		geocache := newBaseCollection("geocache",
			&core.TextField{Name: "service", Required: true},
			&core.TextField{Name: "key", Required: true},
			&core.JSONField{Name: "payload", Required: true, MaxSize: jsonMax},
			&core.DateField{Name: "cached_at", Required: true},
		)
		geocache.Indexes = types.JSONArray[string]{
			"CREATE UNIQUE INDEX idx_geocache_service_key ON geocache (service, key)",
			"CREATE INDEX idx_geocache_cached_at ON geocache (cached_at)",
		}
		return app.Save(geocache)
	}, func(app core.App) error {
		if err := deleteCollectionIfExists(app, "geocache"); err != nil {
			return err
		}
		for _, name := range []string{"samples", "excursions"} {
			coll, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			removeFields(coll, "admin_units", "mtb", "astro")
			if err := app.Save(coll); err != nil {
				return err
			}
		}
		return nil
	})
}
