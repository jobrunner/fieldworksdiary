// Phase O.2 — samples get Ortus location/geo columns.
//
//   - altitude → elevation (rename keeps the field ID, so data sticks)
//   - elevation_source (select), location_status (select), placemark,
//     placemark_suggestion (relations → placemarks, optional, single,
//     no cascade), MTB sheet/quadrant, DEM + terrain + bearing columns.
//
// Backfill: location_status = 'pending' for every existing row (the
// location backfill picks them up); elevation_source = 'location_service'
// where the old altitude is set.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

var samplesOrtusNewFields = []string{
	"elevation_source", "location_status", "placemark", "placemark_suggestion",
	"mtb_sheet_number", "mtb_sheet_name", "mtb_quadrant",
	"elevation_dem", "elevation_dem_accuracy", "slope_deg", "aspect_deg",
	"bearing_distance_km", "aspect_compass", "bearing_label",
	"bearing_reference", "bearing_compass", "terrain_flat", "bearing_inside",
}

func samplesOrtusUp(db dbx.Builder) error {
	dao := daos.New(db)
	samples, err := dao.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	placemarks, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return err
	}
	if f := samples.Schema.GetFieldByName("altitude"); f != nil {
		f.Name = "elevation"
	}
	add := func(f *schema.SchemaField) {
		if samples.Schema.GetFieldByName(f.Name) == nil {
			samples.Schema.AddField(f)
		}
	}
	sel := func(name string, values ...string) *schema.SchemaField {
		return &schema.SchemaField{Name: name, Type: schema.FieldTypeSelect,
			Options: &schema.SelectOptions{Values: values, MaxSelect: 1}}
	}
	rel := func(name string) *schema.SchemaField {
		return &schema.SchemaField{Name: name, Type: schema.FieldTypeRelation,
			Options: &schema.RelationOptions{
				CollectionId:  placemarks.Id,
				CascadeDelete: false,
				MinSelect:     types.Pointer(0),
				MaxSelect:     types.Pointer(1),
			}}
	}
	add(sel("elevation_source", "location_service", "backend_service", "manual"))
	add(sel("location_status", "backend_service", "inherited", "manual", "pending"))
	add(rel("placemark"))
	add(rel("placemark_suggestion"))
	for _, n := range []string{"mtb_sheet_number", "mtb_sheet_name", "mtb_quadrant"} {
		t := schema.FieldTypeText
		add(&schema.SchemaField{Name: n, Type: t})
	}
	for _, n := range []string{"elevation_dem", "elevation_dem_accuracy", "slope_deg",
		"aspect_deg", "bearing_distance_km"} {
		add(&schema.SchemaField{Name: n, Type: schema.FieldTypeNumber})
	}
	for _, n := range []string{"aspect_compass", "bearing_label", "bearing_reference", "bearing_compass"} {
		add(&schema.SchemaField{Name: n, Type: schema.FieldTypeText})
	}
	add(&schema.SchemaField{Name: "terrain_flat", Type: schema.FieldTypeBool})
	add(&schema.SchemaField{Name: "bearing_inside", Type: schema.FieldTypeBool})

	if err := dao.SaveCollection(samples); err != nil {
		return err
	}
	for _, q := range []string{
		`UPDATE samples SET location_status = 'pending'
		 WHERE location_status IS NULL OR location_status = ''`,
		`UPDATE samples SET elevation_source = 'location_service'
		 WHERE elevation IS NOT NULL AND elevation != 0
		   AND (elevation_source IS NULL OR elevation_source = '')`,
	} {
		if _, err := db.NewQuery(q).Execute(); err != nil {
			return err
		}
	}
	return nil
}

func samplesOrtusDown(db dbx.Builder) error {
	dao := daos.New(db)
	samples, err := dao.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	for _, name := range samplesOrtusNewFields {
		if f := samples.Schema.GetFieldByName(name); f != nil {
			samples.Schema.RemoveField(f.Id)
		}
	}
	if f := samples.Schema.GetFieldByName("elevation"); f != nil {
		f.Name = "altitude"
	}
	return dao.SaveCollection(samples)
}

func init() {
	m.Register(samplesOrtusUp, samplesOrtusDown)
}
