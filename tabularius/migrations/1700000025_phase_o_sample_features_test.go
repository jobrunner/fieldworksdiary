package migrations

import (
	"strings"
	"testing"
)

func TestSampleFeaturesMigration_Schema(t *testing.T) {
	app := setupTestApp(t)
	c, err := app.FindCollectionByNameOrId("sample_features")
	if err != nil {
		t.Fatalf("find sample_features: %v", err)
	}
	for _, name := range []string{"owner", "sample", "source_id", "source_name",
		"layer", "feature_id", "properties", "license", "fetched_at"} {
		if c.Fields.GetByName(name) == nil {
			t.Errorf("sample_features.%s missing", name)
		}
	}
	if c.ListRule == nil || !strings.Contains(*c.ListRule, "owner = @request.auth.id") {
		t.Errorf("list rule = %v", c.ListRule)
	}
	if c.CreateRule != nil || c.UpdateRule != nil || c.DeleteRule != nil {
		t.Errorf("write rules must be nil")
	}
	if len(c.Indexes) == 0 {
		t.Errorf("index missing")
	}
}
