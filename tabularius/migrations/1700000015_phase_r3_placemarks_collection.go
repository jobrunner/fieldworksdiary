// Phase R3.1 — `placemarks` reference table.
//
// Stores the parsed reverse-geocoding result that the backend
// derives from a coordinate (country, administrative_area, locality,
// postal_code, …). A `Locality` references a placemark; multiple
// localities may share the same placemark (a 1 km radius cluster
// hitting the same address would be one).
//
// **No `owner` relation.** Placemarks are a reference table: the
// geocoding result for (49.79, 9.94) is the same regardless of who
// asked. List/view is gated to authenticated users; create/update/
// delete are nil so only the backend hook may write.
//
// `dedup_hash` is a content hash built in the backend (NFC-normalised,
// lowercased, `|`-joined `country|administrative_area|locality|
// postal_code`). The unique index makes `lookup-or-create` cheap.
//
// `geocoding_source`:
//   - `backend-service` (default) — written by the auto-geocode hook
//   - `manual` — set when the user has overridden it; future
//     auto-geocode calls skip this placemark.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		if c, err := app.FindCollectionByNameOrId("placemarks"); err == nil && c != nil {
			// Idempotent: already exists, nothing to do.
			return nil
		}

		authedRead := types.Pointer("@request.auth.id != ''")
		placemarks := newBaseCollection("placemarks",
			// ISO 3166-1 alpha-2 country code (e.g. "DE"). Min/max 2.
			&core.TextField{Name: "country", Required: true, Min: 2, Max: 2},
			&core.TextField{Name: "administrative_area"},
			&core.TextField{Name: "sub_administrative_area"},
			&core.TextField{Name: "locality"},
			&core.TextField{Name: "sub_locality"},
			&core.TextField{Name: "postal_code"},
			&core.TextField{Name: "name"},
			&core.TextField{Name: "thoroughfare"},
			&core.SelectField{
				Name:      "geocoding_source",
				Required:  true,
				Values:    []string{"backend-service", "manual"},
				MaxSelect: 1,
			},
			&core.TextField{Name: "geocoding_service_version"},
			&core.DateField{Name: "geocoding_date"},
			&core.TextField{Name: "dedup_hash", Required: true},
		)
		placemarks.Indexes = types.JSONArray[string]{
			"CREATE UNIQUE INDEX idx_placemarks_dedup_hash ON placemarks (dedup_hash)",
		}
		// Authenticated read for everyone; writes are superuser/hook-only.
		// No owner — this is a deduplicated reference table.
		placemarks.ListRule = authedRead
		placemarks.ViewRule = authedRead
		return app.Save(placemarks)
	}, func(app core.App) error {
		return deleteCollectionIfExists(app, "placemarks")
	})
}
