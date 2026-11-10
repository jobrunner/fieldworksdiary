package hooks

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tokens"
)

// makePlacemarkRow seeds a placemark with the given owner ("" = none)
// and geocoding source.
func makePlacemarkRow(t *testing.T, app *tests.TestApp, owner, source, hash string) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("placemarks")
	if err != nil {
		t.Fatalf("placemarks collection: %v", err)
	}
	rec := models.NewRecord(coll)
	rec.Set("country_iso", "DE")
	rec.Set("geocoding_source", source)
	rec.Set("dedup_hash", hash)
	if owner != "" {
		rec.Set("owner", owner)
	}
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save placemark: %v", err)
	}
	return rec
}

type pmFixture struct {
	app                  *tests.TestApp
	alice, bob           *models.Record
	shared, own, foreign *models.Record
	orphan               *models.Record
}

func newPMFixture(t *testing.T) pmFixture {
	t.Helper()
	app := setupTestApp(t)
	alice := createTestUser(t, app, "alice@example.com")
	bob := createTestUser(t, app, "bob@example.com")
	return pmFixture{
		app:     app,
		alice:   alice,
		bob:     bob,
		shared:  makePlacemarkRow(t, app, "", "backend_service", "h-shared"),
		own:     makePlacemarkRow(t, app, alice.Id, "manual", "h-own"),
		foreign: makePlacemarkRow(t, app, bob.Id, "manual", "h-foreign"),
		orphan:  makePlacemarkRow(t, app, "", "manual", "h-orphan"),
	}
}

func TestCheckPlacemarkRefs_SampleCreate(t *testing.T) {
	f := newPMFixture(t)
	cases := []struct {
		name    string
		field   string
		pm      *models.Record
		wantErr bool
	}{
		{"shared placemark ok", "placemark", f.shared, false},
		{"own manual placemark ok", "placemark", f.own, false},
		{"foreign manual placemark rejected", "placemark", f.foreign, true},
		{"orphaned manual placemark rejected", "placemark", f.orphan, true},
		{"foreign manual suggestion rejected", "placemark_suggestion", f.foreign, true},
		{"own suggestion ok", "placemark_suggestion", f.own, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := newSampleRecord(t, f.app)
			rec.Set(c.field, c.pm.Id)
			err := checkPlacemarkRefs(f.app.Dao(), rec, f.alice.Id)
			if (err != nil) != c.wantErr {
				t.Errorf("err = %v, wantErr %v", err, c.wantErr)
			}
		})
	}
}

func TestCheckPlacemarkRefs_LocalityCreate(t *testing.T) {
	f := newPMFixture(t)
	coll, _ := f.app.Dao().FindCollectionByNameOrId("localities")
	for _, c := range []struct {
		pm      *models.Record
		wantErr bool
	}{{f.shared, false}, {f.own, false}, {f.foreign, true}} {
		rec := models.NewRecord(coll)
		rec.Set("placemark", c.pm.Id)
		err := checkPlacemarkRefs(f.app.Dao(), rec, f.alice.Id)
		if (err != nil) != c.wantErr {
			t.Errorf("placemark %s: err = %v, wantErr %v", c.pm.GetString("dedup_hash"), err, c.wantErr)
		}
	}
}

func TestCheckPlacemarkRefs_UpdateOnlyChecksChangedFields(t *testing.T) {
	f := newPMFixture(t)
	// A legacy row already pointing at a now-invisible placemark: an
	// unrelated edit must not be blocked.
	loc := makeLocality(t, f.app, f.alice.Id, 49.7, 9.9)
	loc.Set("placemark", f.orphan.Id)
	if err := f.app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("seed: %v", err)
	}
	fresh, _ := f.app.Dao().FindRecordById("localities", loc.Id)
	fresh.Set("name", "Renamed")
	if err := checkPlacemarkRefs(f.app.Dao(), fresh, f.alice.Id); err != nil {
		t.Errorf("unchanged ref rejected: %v", err)
	}

	fresh.Set("placemark", f.foreign.Id)
	if err := checkPlacemarkRefs(f.app.Dao(), fresh, f.alice.Id); err == nil {
		t.Error("changed foreign ref accepted")
	}
	fresh.Set("placemark", f.own.Id)
	if err := checkPlacemarkRefs(f.app.Dao(), fresh, f.alice.Id); err != nil {
		t.Errorf("own ref rejected: %v", err)
	}
	fresh.Set("placemark", "")
	if err := checkPlacemarkRefs(f.app.Dao(), fresh, f.alice.Id); err != nil {
		t.Errorf("clearing ref rejected: %v", err)
	}
}

func TestPlacemarkRefGuard_HTTPUpdate(t *testing.T) {
	for _, c := range []struct {
		name   string
		pick   func(foreign, shared *models.Record) string
		status int
		events map[string]int
	}{
		{
			"foreign manual rejected",
			func(foreign, _ *models.Record) string { return foreign.Id },
			http.StatusBadRequest,
			map[string]int{"OnRecordBeforeUpdateRequest": 1},
		},
		{
			"shared accepted",
			func(_, shared *models.Record) string { return shared.Id },
			http.StatusOK,
			map[string]int{
				"OnRecordBeforeUpdateRequest": 1,
				"OnRecordAfterUpdateRequest":  1,
				"OnModelBeforeUpdate":         1,
				"OnModelAfterUpdate":          1,
			},
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			app, err := tests.NewTestApp()
			if err != nil {
				t.Fatalf("test-app: %v", err)
			}
			alice := createTestUser(t, app, "alice@example.com")
			bob := createTestUser(t, app, "bob@example.com")
			foreign := makePlacemarkRow(t, app, bob.Id, "manual", "h-foreign")
			shared := makePlacemarkRow(t, app, "", "backend_service", "h-shared")
			sample := newSampleRecord(t, app)
			sample.Set("owner", alice.Id)
			sample.Set("sample_id", "260519/1")
			sample.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))
			if err := app.Dao().SaveRecord(sample); err != nil {
				t.Fatalf("save sample: %v", err)
			}
			tok, err := tokens.NewRecordAuthToken(app, alice)
			if err != nil {
				t.Fatalf("token: %v", err)
			}
			app.ResetEventCalls()
			scenario := tests.ApiScenario{
				Name:            c.name,
				Method:          http.MethodPatch,
				Url:             "/api/collections/samples/records/" + sample.Id,
				Body:            strings.NewReader(`{"placemark":"` + c.pick(foreign, shared) + `"}`),
				RequestHeaders:  map[string]string{"Authorization": tok, "Content-Type": "application/json"},
				ExpectedStatus:  c.status,
				ExpectedContent: []string{`"`},
				ExpectedEvents:  c.events,
				TestAppFactory:  func(_ *testing.T) *tests.TestApp { return app },
				BeforeTestFunc: func(_ *testing.T, app *tests.TestApp, _ *echo.Echo) {
					RegisterPlacemarkRefGuards(app)
				},
			}
			scenario.Test(t)
		})
	}
}
