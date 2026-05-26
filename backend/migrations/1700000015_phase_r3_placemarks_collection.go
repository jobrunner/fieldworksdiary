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
		if c, err := dao.FindCollectionByNameOrId("placemarks"); err == nil && c != nil {
			// Idempotent: already exists, nothing to do.
			return nil
		}

		authedRead := types.Pointer("@request.auth.id != ''")
		placemarks := &models.Collection{
			Name: "placemarks",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				// ISO 3166-1 alpha-2 country code (e.g. "DE"). Min/max 2.
				&schema.SchemaField{
					Name:     "country",
					Type:     schema.FieldTypeText,
					Required: true,
					Options: &schema.TextOptions{
						Min: types.Pointer(2),
						Max: types.Pointer(2),
					},
				},
				&schema.SchemaField{Name: "administrative_area", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "sub_administrative_area", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "locality", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "sub_locality", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "postal_code", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "name", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "thoroughfare", Type: schema.FieldTypeText},
				&schema.SchemaField{
					Name:     "geocoding_source",
					Type:     schema.FieldTypeSelect,
					Required: true,
					Options: &schema.SelectOptions{
						Values:    []string{"backend-service", "manual"},
						MaxSelect: 1,
					},
				},
				&schema.SchemaField{Name: "geocoding_service_version", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "geocoding_date", Type: schema.FieldTypeDate},
				&schema.SchemaField{
					Name:     "dedup_hash",
					Type:     schema.FieldTypeText,
					Required: true,
				},
			),
			Indexes: types.JsonArray[string]{
				"CREATE UNIQUE INDEX idx_placemarks_dedup_hash ON placemarks (dedup_hash)",
			},
			// Authenticated read for everyone; writes are admin/hook-only.
			// No owner — this is a deduplicated reference table.
			ListRule:   authedRead,
			ViewRule:   authedRead,
			CreateRule: nil,
			UpdateRule: nil,
			DeleteRule: nil,
		}
		return dao.SaveCollection(placemarks)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		if c, err := dao.FindCollectionByNameOrId("placemarks"); err == nil && c != nil {
			return dao.DeleteCollection(c)
		}
		return nil
	})
}
