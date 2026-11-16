// Phase R3.2 — localities gain the explicit point-location columns
// plus sync-idempotency fields, a placemark relation, and a
// monotone `version`.
//
// Adds (all initially optional; the create-hook fills `latitude`/
// `longitude` from the originating sample, the geocoding hook fills
// `placemark` later, the client supplies `client_uuid`/
// `client_updated_at`):
//
//   - latitude, longitude            — explicit point location;
//     replaces the older `centroid_*` semantics (those stay for now
//     until R5 cuts them).
//   - altitude, horizontal_accuracy, vertical_accuracy
//   - location_source — Select: user | location_service | sample |
//     locality. Required at use-site; left optional in the schema so
//     the validator doesn't kill legacy rows before the backfill.
//   - location_number — project-local FO number, not unique.
//   - placemark        — relation → placemarks, single, optional.
//   - version          — monotone integer for conflict detection.
//   - client_uuid, client_updated_at — same idempotency layer the
//     other sync-capable collections use.
//
// Data migration:
//   - Copy `centroid_lat → latitude` and `centroid_lon → longitude`
//     for every existing row. We deliberately keep the legacy
//     columns around until R5 to make the rename non-destructive in
//     case anything still reads them.
//   - Backfill `location_source = "user"` and `version = 1` so
//     subsequent updates don't trip on an empty required-ish field.
//
// Index: composite `(latitude, longitude)` so the future Fusion hook
// can do bounding-box queries instead of a full table scan.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		placemarks, err := app.FindCollectionByNameOrId("placemarks")
		if err != nil {
			return err
		}

		addFieldIfMissing(localities, &core.NumberField{Name: "latitude"})
		addFieldIfMissing(localities, &core.NumberField{Name: "longitude"})
		addFieldIfMissing(localities, &core.NumberField{Name: "altitude"})
		addFieldIfMissing(localities, &core.NumberField{Name: "horizontal_accuracy"})
		addFieldIfMissing(localities, &core.NumberField{Name: "vertical_accuracy"})
		addFieldIfMissing(localities, &core.SelectField{
			Name:      "location_source",
			Values:    []string{"user", "location_service", "sample", "locality"},
			MaxSelect: 1,
		})
		addFieldIfMissing(localities, &core.TextField{Name: "location_number"})
		addFieldIfMissing(localities, &core.RelationField{
			Name:          "placemark",
			CollectionId:  placemarks.Id,
			CascadeDelete: false,
			MinSelect:     0,
			MaxSelect:     1,
		})
		addFieldIfMissing(localities, &core.NumberField{Name: "version"})
		addFieldIfMissing(localities, &core.TextField{Name: "client_uuid"})
		addFieldIfMissing(localities, &core.DateField{Name: "client_updated_at"})

		// Composite spatial index for fusion lookups.
		hasSpatialIndex := false
		for _, stmt := range localities.Indexes {
			if stmt == "CREATE INDEX idx_localities_lat_lon ON localities (latitude, longitude)" {
				hasSpatialIndex = true
				break
			}
		}
		if !hasSpatialIndex {
			localities.Indexes = append(localities.Indexes,
				"CREATE INDEX idx_localities_lat_lon ON localities (latitude, longitude)")
		}

		if err := app.Save(localities); err != nil {
			return err
		}

		// Data migration: copy centroid_* → latitude/longitude and
		// default location_source / version on existing rows. We use
		// raw SQL to bypass PocketBase's per-record save (which would
		// run hooks and rules and balloon the migration to minutes
		// even for tiny tables).
		for _, q := range []string{
			`UPDATE localities
			SET latitude = centroid_lat,
			    longitude = centroid_lon
			WHERE latitude IS NULL OR latitude = 0`,
			`UPDATE localities
			SET location_source = 'user'
			WHERE location_source IS NULL OR location_source = ''`,
			`UPDATE localities
			SET version = 1
			WHERE version IS NULL OR version = 0`,
		} {
			if _, err := app.DB().NewQuery(q).Execute(); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		localities, err := app.FindCollectionByNameOrId("localities")
		if err != nil {
			return err
		}
		removeFields(localities,
			"latitude", "longitude", "altitude",
			"horizontal_accuracy", "vertical_accuracy",
			"location_source", "location_number", "placemark",
			"version", "client_uuid", "client_updated_at",
		)
		localities.Indexes = filterIndexes(localities.Indexes, func(s string) bool {
			return s != "CREATE INDEX idx_localities_lat_lon ON localities (latitude, longitude)"
		})
		return app.Save(localities)
	})
}
