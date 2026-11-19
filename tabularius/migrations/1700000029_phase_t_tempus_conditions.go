// Phase T — Wetter, Klima und Astronomie über Tempus.
//
//   - samples: conditions_status (select pending/provisional/final,
//     empty = never processed), conditions_queried_for,
//     conditions_fetched_at, conditions_retry_at (dates),
//     conditions_fields (JSON list of the value columns Tempus
//     delivered) and the value columns for weather, antecedent
//     precipitation, day extrema, climate, sun and moon.
//   - Number columns cannot be empty in PocketBase (a missing value
//     reads 0, and 0 °C is a real value): a value column counts only
//     when it is listed in conditions_fields.
//   - Index on (conditions_status, conditions_retry_at) for the hourly
//     refresh job.
//
// Existing rows are not touched: their status stays empty until the
// backfill fills them. Down removes fields and index again.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

const phaseTIndexName = "idx_samples_conditions_due"

func phaseTFields() []core.Field {
	fields := []core.Field{
		&core.SelectField{
			Name:      "conditions_status",
			Values:    []string{"pending", "provisional", "final"},
			MaxSelect: 1,
		},
		&core.DateField{Name: "conditions_queried_for"},
		&core.DateField{Name: "conditions_fetched_at"},
		&core.DateField{Name: "conditions_retry_at"},
		&core.JSONField{Name: "conditions_fields"},
	}
	for _, name := range []string{
		"weather_temperature_c", "weather_humidity_pct", "weather_dew_point_c",
		"weather_precipitation_mm", "weather_wind_speed_kmh", "weather_cloud_cover_pct",
		"weather_code",
		"precipitation_24h_mm", "precipitation_72h_mm", "precipitation_120h_mm",
		"day_temperature_min_c", "day_temperature_max_c", "day_temperature_mean_c",
	} {
		fields = append(fields, &core.NumberField{Name: name})
	}
	return append(fields,
		&core.TextField{Name: "climate_koppen_code"},
		&core.TextField{Name: "climate_altitudinal_belt"},
		&core.DateField{Name: "sunrise"},
		&core.DateField{Name: "sunset"},
		&core.TextField{Name: "moon_phase"},
		&core.NumberField{Name: "moon_illumination_pct"},
	)
}

func phaseTUp(app core.App) error {
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	for _, f := range phaseTFields() {
		addFieldIfMissing(samples, f)
	}
	samples.AddIndex(phaseTIndexName, false, "conditions_status, conditions_retry_at", "")
	return app.Save(samples)
}

func phaseTDown(app core.App) error {
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	samples.RemoveIndex(phaseTIndexName)
	names := make([]string, 0, len(phaseTFields()))
	for _, f := range phaseTFields() {
		names = append(names, f.GetName())
	}
	removeFields(samples, names...)
	return app.Save(samples)
}

func init() {
	m.Register(phaseTUp, phaseTDown)
}
