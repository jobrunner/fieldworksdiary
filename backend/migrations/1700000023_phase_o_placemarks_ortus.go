// Phase O.1 — placemarks get flat per-tier columns for Ortus data.
//
//   - country_iso, admin_<tier>, admin_<tier>_level, admin_<tier>_native
//     (tiers from adminlabels.Tiers), island, mountain_range, mountain
//   - owner → users (optional; empty = shared reference row)
//   - geocoding_source values become `backend_service` | `manual`
//     (existing rows are renamed from `backend-service`).
//   - The UNIQUE index on dedup_hash is replaced by a non-unique
//     composite (dedup_hash, geocoding_source, owner). Uniqueness is
//     guaranteed by LookupOrCreate; a UNIQUE index would make
//     PocketBase derive a form validator (see Phase 3b / 1700000017).
//   - Rules: list/view for authenticated users on shared rows (ownerless
//     AND backend_service) or own rows; writes backend-only.
//
// Legacy columns (administrative_area, …) stay until O3.
package migrations

import (
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

const (
	placemarksUniqueIdx = "CREATE UNIQUE INDEX idx_placemarks_dedup_hash ON placemarks (dedup_hash)"
	placemarksCompIdx   = "CREATE INDEX idx_placemarks_dedup_source_owner ON placemarks (dedup_hash, geocoding_source, owner)"
)

func placemarksOrtusFieldNames() []string {
	names := []string{"country_iso", "island", "mountain_range", "mountain", "owner"}
	for _, tier := range adminlabels.Tiers {
		s := string(tier)
		names = append(names, s, s+"_level", s+"_native")
	}
	return names
}

func placemarksOrtusUp(db dbx.Builder) error {
	dao := daos.New(db)
	pm, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return err
	}
	users, err := dao.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	add := func(f *schema.SchemaField) {
		if pm.Schema.GetFieldByName(f.Name) == nil {
			pm.Schema.AddField(f)
		}
	}
	text := func(name string) *schema.SchemaField {
		return &schema.SchemaField{Name: name, Type: schema.FieldTypeText}
	}
	add(text("country_iso"))
	for _, tier := range adminlabels.Tiers {
		s := string(tier)
		add(text(s))
		add(&schema.SchemaField{Name: s + "_level", Type: schema.FieldTypeNumber})
		add(text(s + "_native"))
	}
	add(text("island"))
	add(text("mountain_range"))
	add(text("mountain"))
	add(&schema.SchemaField{
		Name: "owner",
		Type: schema.FieldTypeRelation,
		Options: &schema.RelationOptions{
			CollectionId:  users.Id,
			CascadeDelete: false,
			MinSelect:     types.Pointer(0),
			MaxSelect:     types.Pointer(1),
		},
	})
	if f := pm.Schema.GetFieldByName("geocoding_source"); f != nil {
		f.Options = &schema.SelectOptions{
			Values:    []string{"backend_service", "manual"},
			MaxSelect: 1,
		}
	}

	idx := filterIndexes(pm.Indexes, func(s string) bool {
		return !strings.Contains(s, "idx_placemarks_dedup_hash") &&
			!strings.Contains(s, "idx_placemarks_dedup_source_owner")
	})
	pm.Indexes = append(idx, placemarksCompIdx)

	// Shared = ownerless AND backend-produced. A manual row whose owner
	// was cleared (account deletion) must not become world-readable.
	// Twin of geoplace.VisibleTo.
	rule := types.Pointer("@request.auth.id != '' && ((owner = '' && geocoding_source = 'backend_service') || owner = @request.auth.id)")
	pm.ListRule = rule
	pm.ViewRule = rule
	pm.CreateRule, pm.UpdateRule, pm.DeleteRule = nil, nil, nil

	if err := dao.SaveCollection(pm); err != nil {
		return err
	}
	_, err = db.NewQuery(`UPDATE placemarks SET geocoding_source = 'backend_service'
		WHERE geocoding_source = 'backend-service'`).Execute()
	return err
}

func placemarksOrtusDown(db dbx.Builder) error {
	dao := daos.New(db)
	pm, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return err
	}
	if _, err := db.NewQuery(`UPDATE placemarks SET geocoding_source = 'backend-service'
		WHERE geocoding_source = 'backend_service'`).Execute(); err != nil {
		return err
	}
	for _, name := range placemarksOrtusFieldNames() {
		if f := pm.Schema.GetFieldByName(name); f != nil {
			pm.Schema.RemoveField(f.Id)
		}
	}
	if f := pm.Schema.GetFieldByName("geocoding_source"); f != nil {
		f.Options = &schema.SelectOptions{
			Values:    []string{"backend-service", "manual"},
			MaxSelect: 1,
		}
	}
	idx := filterIndexes(pm.Indexes, func(s string) bool {
		return !strings.Contains(s, "idx_placemarks_dedup_source_owner") &&
			!strings.Contains(s, "idx_placemarks_dedup_hash")
	})
	pm.Indexes = append(idx, placemarksUniqueIdx)
	rule := types.Pointer("@request.auth.id != ''")
	pm.ListRule = rule
	pm.ViewRule = rule
	return dao.SaveCollection(pm)
}

func init() {
	m.Register(placemarksOrtusUp, placemarksOrtusDown)
}
