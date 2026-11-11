package migrations

import (
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

func TestPlacemarksOrtusMigration_Schema(t *testing.T) {
	app := setupTestApp(t)
	pm, err := app.FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatalf("find placemarks: %v", err)
	}
	want := []string{"country_iso", "island", "mountain_range", "mountain", "owner"}
	for _, tier := range adminlabels.Tiers {
		s := string(tier)
		want = append(want, s, s+"_level", s+"_native")
	}
	for _, name := range want {
		if pm.Fields.GetByName(name) == nil {
			t.Errorf("placemarks.%s missing", name)
		}
	}
	for _, idx := range pm.Indexes {
		if strings.Contains(strings.ToUpper(idx), "UNIQUE") {
			t.Errorf("unexpected unique index: %s", idx)
		}
	}
	found := false
	for _, idx := range pm.Indexes {
		if strings.Contains(idx, "idx_placemarks_dedup_source_owner") {
			found = true
		}
	}
	if !found {
		t.Errorf("composite index missing: %v", pm.Indexes)
	}
	if pm.ListRule == nil || !strings.Contains(*pm.ListRule, "owner = '' && geocoding_source = 'backend_service'") {
		t.Errorf("list rule = %v", pm.ListRule)
	}
	if pm.CreateRule != nil || pm.UpdateRule != nil || pm.DeleteRule != nil {
		t.Errorf("write rules must be nil")
	}
}

func TestPlacemarksMigration_RenamesBackendService(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app
	// Revert, seed a legacy row, re-apply the up-step.
	if err := placemarksOrtusDown(dao); err != nil {
		t.Fatalf("down: %v", err)
	}
	if _, err := dao.DB().NewQuery(
		`INSERT INTO placemarks (id, country, geocoding_source, dedup_hash)
		 VALUES ('legacy00000001', 'DE', 'backend-service', 'h1')`).Execute(); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := placemarksOrtusUp(dao); err != nil {
		t.Fatalf("up: %v", err)
	}
	var src string
	if err := dao.DB().NewQuery(`SELECT geocoding_source FROM placemarks WHERE id='legacy00000001'`).
		Row(&src); err != nil {
		t.Fatalf("select: %v", err)
	}
	if src != "backend_service" {
		t.Errorf("geocoding_source = %q, want backend_service", src)
	}
}

func TestPlacemarksOrtusMigration_DownRestores(t *testing.T) {
	app := setupLegacyLocationTestApp(t)
	dao := app
	if err := placemarksOrtusDown(dao); err != nil {
		t.Fatalf("down: %v", err)
	}
	pm, _ := dao.FindCollectionByNameOrId("placemarks")
	if pm.Fields.GetByName("country_iso") != nil {
		t.Errorf("country_iso still present after down")
	}
	if pm.Fields.GetByName("administrative_area") == nil {
		t.Errorf("legacy column lost")
	}
	for _, r := range []*string{pm.ListRule, pm.ViewRule} {
		if r == nil || *r != "@request.auth.id != ''" {
			t.Errorf("rule after down = %v, want pre-O rule", r)
		}
	}
}

func TestPlacemarksOrtusMigration_ViewRuleHidesOrphanedManualRows(t *testing.T) {
	app := setupTestApp(t)
	dao := app
	users, _ := dao.FindCollectionByNameOrId("users")
	mkUser := func(email string) *core.Record {
		u := core.NewRecord(users)
		u.SetEmail(email)
		u.Set("username", strings.SplitN(email, "@", 2)[0])
		u.SetPassword("password1234")
		if err := dao.SaveNoValidate(u); err != nil {
			t.Fatalf("user: %v", err)
		}
		return u
	}
	alice := mkUser("alice@example.com")
	bob := mkUser("bob@example.com")
	pmColl, _ := dao.FindCollectionByNameOrId("placemarks")
	mkPM := func(owner, source, hash string) *core.Record {
		r := core.NewRecord(pmColl)
		r.Set("country", "DE")
		r.Set("geocoding_source", source)
		r.Set("dedup_hash", hash)
		if owner != "" {
			r.Set("owner", owner)
		}
		if err := dao.SaveNoValidate(r); err != nil {
			t.Fatalf("placemark: %v", err)
		}
		return r
	}
	cases := []struct {
		name string
		rec  *core.Record
		want bool
	}{
		{"shared backend row", mkPM("", "backend_service", "h1"), true},
		{"own manual row", mkPM(alice.Id, "manual", "h2"), true},
		{"foreign manual row", mkPM(bob.Id, "manual", "h3"), false},
		{"orphaned manual row", mkPM("", "manual", "h4"), false},
	}
	info := &core.RequestInfo{Auth: alice}
	for _, rule := range []*string{pmColl.ListRule, pmColl.ViewRule} {
		for _, c := range cases {
			got, err := dao.CanAccessRecord(c.rec, info, rule)
			if err != nil {
				t.Fatalf("%s: %v", c.name, err)
			}
			if got != c.want {
				t.Errorf("%s: access = %v, want %v (rule %q)", c.name, got, c.want, *rule)
			}
		}
	}
}
