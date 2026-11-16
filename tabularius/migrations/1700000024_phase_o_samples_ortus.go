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
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

var samplesOrtusNewFields = []string{
	"elevation_source", "location_status", "placemark", "placemark_suggestion",
	"mtb_sheet_number", "mtb_sheet_name", "mtb_quadrant",
	"elevation_dem", "elevation_dem_accuracy", "slope_deg", "aspect_deg",
	"bearing_distance_km", "aspect_compass", "bearing_label",
	"bearing_reference", "bearing_compass", "terrain_flat", "bearing_inside",
}

func samplesOrtusUp(app core.App) error {
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	placemarks, err := app.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return err
	}
	renameField(samples, "altitude", "elevation")
	sel := func(name string, values ...string) core.Field {
		return &core.SelectField{Name: name, Values: values, MaxSelect: 1}
	}
	rel := func(name string) core.Field {
		return &core.RelationField{
			Name:          name,
			CollectionId:  placemarks.Id,
			CascadeDelete: false,
			MinSelect:     0,
			MaxSelect:     1,
		}
	}
	addFieldIfMissing(samples, sel("elevation_source", "location_service", "backend_service", "manual"))
	addFieldIfMissing(samples, sel("location_status", "backend_service", "inherited", "manual", "pending"))
	addFieldIfMissing(samples, rel("placemark"))
	addFieldIfMissing(samples, rel("placemark_suggestion"))
	addFieldIfMissing(samples, &core.NumberField{Name: "mtb_quadrant"})
	for _, n := range []string{"mtb_sheet_number", "mtb_sheet_name"} {
		addFieldIfMissing(samples, &core.TextField{Name: n})
	}
	for _, n := range []string{
		"elevation_dem", "elevation_dem_accuracy", "slope_deg",
		"aspect_deg", "bearing_distance_km",
	} {
		addFieldIfMissing(samples, &core.NumberField{Name: n})
	}
	for _, n := range []string{"aspect_compass", "bearing_label", "bearing_reference", "bearing_compass"} {
		addFieldIfMissing(samples, &core.TextField{Name: n})
	}
	addFieldIfMissing(samples, &core.BoolField{Name: "terrain_flat"})
	addFieldIfMissing(samples, &core.BoolField{Name: "bearing_inside"})

	if err := app.Save(samples); err != nil {
		return err
	}
	for _, q := range []string{
		`UPDATE samples SET location_status = 'pending'
		 WHERE location_status IS NULL OR location_status = ''`,
		`UPDATE samples SET elevation_source = 'location_service'
		 WHERE elevation IS NOT NULL AND elevation != 0
		   AND (elevation_source IS NULL OR elevation_source = '')`,
	} {
		if _, err := app.DB().NewQuery(q).Execute(); err != nil {
			return err
		}
	}
	return nil
}

func samplesOrtusDown(app core.App) error {
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	removeFields(samples, samplesOrtusNewFields...)
	renameField(samples, "elevation", "altitude")
	return app.Save(samples)
}

func init() {
	m.Register(samplesOrtusUp, samplesOrtusDown)
}
