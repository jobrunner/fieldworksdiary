// Phase O3 — drop the legacy location columns and the dead ID counter.
//
//   - placemarks: country, administrative_area, sub_administrative_area,
//     locality, sub_locality, postal_code, name, thoroughfare
//     (replaced by country_iso + admin_<tier> in Phase O.1)
//   - samples: mtb (JSON; replaced by mtb_sheet_number/_name/_quadrant)
//   - fieldtrips: admin_units, mtb, country, admin_area (plus their indexes)
//   - collection sample_sequences (the backend no longer assigns IDs
//     since Phase Z)
//
// Before dropping, Up maps the legacy texts of manual placemarks onto the
// flat columns (geoplace.MapLegacyManualPlacemarks: owner, per-owner
// clones, one log line per row with old and new values). Production
// jumps from migration 22 to 27 in one `serve`, so this cannot wait for
// the post-deploy `ortus-backfill` job.
//
// Down restores the columns and the empty collection, without data.
package migrations

import (
	"fmt"
	"log/slog"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"

	"go.mett.io/fwd-backend/internal/geoplace"
)

var legacyLocationFields = map[string][]string{
	"placemarks": geoplace.LegacyPlacemarkFields,
	"samples":    {"mtb"},
	"fieldtrips": {"admin_units", "mtb", "country", "admin_area"},
}

const (
	fieldtripsCountryIdx   = "CREATE INDEX idx_fieldtrips_country ON fieldtrips (country)"
	fieldtripsAdminAreaIdx = "CREATE INDEX idx_fieldtrips_admin_area ON fieldtrips (admin_area)"
)

func dropLegacyLocationUp(db dbx.Builder) error {
	dao := daos.New(db)
	if _, err := geoplace.MapLegacyManualPlacemarks(dao, slog.Default()); err != nil {
		return fmt.Errorf("map legacy manual placemarks: %w", err)
	}
	for _, name := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, err := dao.FindCollectionByNameOrId(name)
		if err != nil {
			return err
		}
		if name == "fieldtrips" {
			coll.Indexes = filterIndexes(coll.Indexes, func(s string) bool {
				return !strings.Contains(s, "idx_fieldtrips_country") &&
					!strings.Contains(s, "idx_fieldtrips_admin_area")
			})
		}
		for _, f := range legacyLocationFields[name] {
			if sf := coll.Schema.GetFieldByName(f); sf != nil {
				coll.Schema.RemoveField(sf.Id)
			}
		}
		if err := dao.SaveCollection(coll); err != nil {
			return err
		}
	}
	if seq, err := dao.FindCollectionByNameOrId("sample_sequences"); err == nil {
		return dao.DeleteCollection(seq)
	}
	return nil
}

func dropLegacyLocationDown(db dbx.Builder) error {
	dao := daos.New(db)
	text := func(n string) *schema.SchemaField {
		return &schema.SchemaField{Name: n, Type: schema.FieldTypeText}
	}
	fields := map[string][]*schema.SchemaField{
		"placemarks": {
			text("country"),
			text("administrative_area"), text("sub_administrative_area"), text("locality"),
			text("sub_locality"), text("postal_code"), text("name"), text("thoroughfare"),
		},
		"samples": {{Name: "mtb", Type: schema.FieldTypeJson, Options: &schema.JsonOptions{MaxSize: 2000000}}},
		"fieldtrips": {
			{Name: "admin_units", Type: schema.FieldTypeJson, Options: &schema.JsonOptions{MaxSize: 2000000}},
			{Name: "mtb", Type: schema.FieldTypeJson, Options: &schema.JsonOptions{MaxSize: 2000000}},
			text("country"), text("admin_area"),
		},
	}
	for _, name := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, err := dao.FindCollectionByNameOrId(name)
		if err != nil {
			return err
		}
		for _, f := range fields[name] {
			if coll.Schema.GetFieldByName(f.Name) == nil {
				coll.Schema.AddField(f)
			}
		}
		if name == "fieldtrips" {
			coll.Indexes = append(filterIndexes(coll.Indexes, func(s string) bool {
				return !strings.Contains(s, "idx_fieldtrips_country") &&
					!strings.Contains(s, "idx_fieldtrips_admin_area")
			}), fieldtripsCountryIdx, fieldtripsAdminAreaIdx)
		}
		if err := dao.SaveCollection(coll); err != nil {
			return err
		}
	}
	if _, err := dao.FindCollectionByNameOrId("sample_sequences"); err == nil {
		return nil
	}
	users, err := dao.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	return dao.SaveCollection(&models.Collection{
		Name: "sample_sequences",
		Type: models.CollectionTypeBase,
		Schema: schema.NewSchema(
			&schema.SchemaField{Name: "collecting_day", Type: schema.FieldTypeText, Required: true},
			&schema.SchemaField{Name: "last_seq", Type: schema.FieldTypeNumber, Required: true},
			&schema.SchemaField{
				Name: "owner", Type: schema.FieldTypeRelation,
				Options: &schema.RelationOptions{
					CollectionId: users.Id, MinSelect: types.Pointer(0), MaxSelect: types.Pointer(1),
				},
			},
		),
		Indexes: types.JsonArray[string]{
			"CREATE UNIQUE INDEX idx_sample_sequences_owner_day ON sample_sequences (owner, collecting_day)",
		},
	})
}

func init() {
	m.Register(dropLegacyLocationUp, dropLegacyLocationDown)
}
