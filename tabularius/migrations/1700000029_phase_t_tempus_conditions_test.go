package migrations

import (
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

// wantPhaseTFields lists every field Phase T adds to samples with its
// PocketBase field type.
var wantPhaseTFields = map[string]string{
	"conditions_status":        core.FieldTypeSelect,
	"conditions_queried_for":   core.FieldTypeDate,
	"conditions_fetched_at":    core.FieldTypeDate,
	"conditions_retry_at":      core.FieldTypeDate,
	"conditions_kinds":         core.FieldTypeJSON,
	"weather_temperature_c":    core.FieldTypeNumber,
	"weather_humidity_pct":     core.FieldTypeNumber,
	"weather_dew_point_c":      core.FieldTypeNumber,
	"weather_precipitation_mm": core.FieldTypeNumber,
	"weather_wind_speed_kmh":   core.FieldTypeNumber,
	"weather_cloud_cover_pct":  core.FieldTypeNumber,
	"weather_code":             core.FieldTypeNumber,
	"precipitation_24h_mm":     core.FieldTypeNumber,
	"precipitation_72h_mm":     core.FieldTypeNumber,
	"precipitation_120h_mm":    core.FieldTypeNumber,
	"day_temperature_min_c":    core.FieldTypeNumber,
	"day_temperature_max_c":    core.FieldTypeNumber,
	"day_temperature_mean_c":   core.FieldTypeNumber,
	"climate_koppen_code":      core.FieldTypeText,
	"climate_altitudinal_belt": core.FieldTypeText,
	"sunrise":                  core.FieldTypeDate,
	"sunset":                   core.FieldTypeDate,
	"moon_phase":               core.FieldTypeText,
	"moon_illumination_pct":    core.FieldTypeNumber,
}

func hasConditionsIndex(c *core.Collection) bool {
	for _, idx := range c.Indexes {
		if strings.Contains(idx, "idx_samples_conditions_due") {
			return true
		}
	}
	return false
}

func TestPhaseTAddsConditionFields(t *testing.T) {
	app := setupTestApp(t)
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatal(err)
	}
	for name, typ := range wantPhaseTFields {
		f := samples.Fields.GetByName(name)
		if f == nil {
			t.Errorf("field %s missing", name)
			continue
		}
		if f.Type() != typ {
			t.Errorf("field %s: type %s, want %s", name, f.Type(), typ)
		}
	}
	sel, ok := samples.Fields.GetByName("conditions_status").(*core.SelectField)
	if !ok {
		t.Fatal("conditions_status is not a select field")
	}
	if got := strings.Join(sel.Values, ","); got != "pending,provisional,final" {
		t.Errorf("conditions_status values = %q", got)
	}
	if sel.Required {
		t.Error("conditions_status must allow the empty value")
	}
	if !hasConditionsIndex(samples) {
		t.Error("index idx_samples_conditions_due missing")
	}
}

// Existing rows keep an empty status: only the backfill fills them.
func TestPhaseTLeavesExistingSamplesUntouched(t *testing.T) {
	app := setupTestApp(t)
	if err := phaseTDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	if _, err := app.DB().NewQuery(`INSERT INTO samples (id) VALUES ('smpt00000000001')`).Execute(); err != nil {
		t.Fatal(err)
	}
	if err := phaseTUp(app); err != nil {
		t.Fatalf("up: %v", err)
	}
	var status string
	if err := app.DB().NewQuery(`SELECT COALESCE(conditions_status, '') FROM samples WHERE id='smpt00000000001'`).
		Row(&status); err != nil {
		t.Fatal(err)
	}
	if status != "" {
		t.Errorf("conditions_status = %q, want empty", status)
	}
}

func TestPhaseTDownRemovesFields(t *testing.T) {
	app := setupTestApp(t)
	if err := phaseTDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatal(err)
	}
	for name := range wantPhaseTFields {
		if samples.Fields.GetByName(name) != nil {
			t.Errorf("field %s still present after down", name)
		}
	}
	if hasConditionsIndex(samples) {
		t.Error("index still present after down")
	}
}
