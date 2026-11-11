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

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
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

func dropLegacyLocationUp(app core.App) error {
	if _, err := geoplace.MapLegacyManualPlacemarks(app, slog.Default()); err != nil {
		return fmt.Errorf("map legacy manual placemarks: %w", err)
	}
	for _, name := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			return err
		}
		if name == "fieldtrips" {
			coll.Indexes = filterIndexes(coll.Indexes, func(s string) bool {
				return !strings.Contains(s, "idx_fieldtrips_country") &&
					!strings.Contains(s, "idx_fieldtrips_admin_area")
			})
		}
		removeFields(coll, legacyLocationFields[name]...)
		if err := app.Save(coll); err != nil {
			return err
		}
	}
	return deleteCollectionIfExists(app, "sample_sequences")
}

func dropLegacyLocationDown(app core.App) error {
	text := func(n string) core.Field {
		return &core.TextField{Name: n}
	}
	jsonField := func(n string) core.Field {
		return &core.JSONField{Name: n, MaxSize: 2000000}
	}
	fields := map[string][]core.Field{
		"placemarks": {
			text("country"),
			text("administrative_area"), text("sub_administrative_area"), text("locality"),
			text("sub_locality"), text("postal_code"), text("name"), text("thoroughfare"),
		},
		"samples": {jsonField("mtb")},
		"fieldtrips": {
			jsonField("admin_units"), jsonField("mtb"),
			text("country"), text("admin_area"),
		},
	}
	for _, name := range []string{"placemarks", "samples", "fieldtrips"} {
		coll, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			return err
		}
		for _, f := range fields[name] {
			addFieldIfMissing(coll, f)
		}
		if name == "fieldtrips" {
			coll.Indexes = append(filterIndexes(coll.Indexes, func(s string) bool {
				return !strings.Contains(s, "idx_fieldtrips_country") &&
					!strings.Contains(s, "idx_fieldtrips_admin_area")
			}), fieldtripsCountryIdx, fieldtripsAdminAreaIdx)
		}
		if err := app.Save(coll); err != nil {
			return err
		}
	}
	if _, err := app.FindCollectionByNameOrId("sample_sequences"); err == nil {
		return nil
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	seq := newBaseCollection("sample_sequences",
		&core.TextField{Name: "collecting_day", Required: true},
		&core.NumberField{Name: "last_seq", Required: true},
		&core.RelationField{
			Name: "owner", CollectionId: users.Id, MinSelect: 0, MaxSelect: 1,
		},
	)
	seq.Indexes = types.JSONArray[string]{
		"CREATE UNIQUE INDEX idx_sample_sequences_owner_day ON sample_sequences (owner, collecting_day)",
	}
	return app.Save(seq)
}

func init() {
	m.Register(dropLegacyLocationUp, dropLegacyLocationDown)
}
