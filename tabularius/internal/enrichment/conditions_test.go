package enrichment

import (
	"context"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/tabularius/internal/conditions"
	"go.mett.io/tabularius/internal/geoplace"
	"go.mett.io/tabularius/internal/services"
)

// fakeTempus serves one fixture, records the datetime parameters it was
// asked for and can be switched to failing.
type fakeTempus struct {
	mu        sync.Mutex
	srv       *httptest.Server
	body      []byte
	fail      bool
	datetimes []string
	// elevations are the elevation parameters of the requests.
	elevations []string
}

func newFakeTempus(t *testing.T, fixture string) *fakeTempus {
	t.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "tempus", fixture))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	f := &fakeTempus{body: body}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.datetimes = append(f.datetimes, r.URL.Query().Get("datetime"))
		f.elevations = append(f.elevations, r.URL.Query().Get("elevation"))
		if f.fail {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(f.body)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeTempus) hits() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.datetimes)
}

// condNow is "now" for the enricher: long after the sample of
// createOwnerSampleFieldtrip (2026-05-19T15:00Z), so answers are final.
var condNow = time.Date(2026, 8, 1, 9, 0, 0, 0, time.UTC)

func newConditionsEnricher(app *tests.TestApp, f *fakeTempus, now time.Time) *ConditionsEnricher {
	return &ConditionsEnricher{
		App: app,
		Tempus: &services.Tempus{
			BaseURL:    f.srv.URL,
			HTTPClient: &http.Client{Timeout: 2 * time.Second},
			MaxRetries: 1,
		},
		Timeout: 5 * time.Second,
		Now:     func() time.Time { return now },
	}
}

func pendingSample(t *testing.T, app *tests.TestApp) (ownerID, sampleID, ftID string) {
	t.Helper()
	ownerID, sampleID, ftID = createOwnerSampleFieldtrip(t, app, 48.1351, 11.582)
	updateSample(t, app, sampleID, map[string]any{
		"conditions_status": conditions.StatusPending, "timezone": "Europe/Berlin", "version": 3,
		"elevation": 519.6, "elevation_source": "location_service",
	})
	return
}

// extraSample adds another sample (same place and time, status empty)
// for an existing owner and fieldtrip.
func extraSample(t *testing.T, app *tests.TestApp, ownerID, ftID string) string {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatal(err)
	}
	rec := core.NewRecord(coll)
	rec.Set("owner", ownerID)
	rec.Set("fieldtrip", ftID)
	rec.Set("latitude", 48.1351)
	rec.Set("longitude", 11.582)
	rec.Set("timezone", "Europe/Berlin")
	rec.Set("begin_date", time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC))
	rec.Set("elevation", 519.6)
	rec.Set("elevation_source", "location_service")
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	return rec.Id
}

func tempusRows(t *testing.T, app *tests.TestApp, sampleID string) int {
	t.Helper()
	n := 0
	for _, f := range sampleFeatures(t, app, sampleID) {
		if geoplace.ScopeOf(f.GetString("source_id")) == geoplace.ScopeTempus {
			n++
		}
	}
	return n
}

func TestEnrich_PendingBecomesFinalAndWritesFeatures(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	newConditionsEnricher(app, f, condNow).EnrichSample(context.Background(), sampleID)

	s := loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusFinal {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
	if s.GetInt("version") != 4 {
		t.Errorf("version = %d, want 4", s.GetInt("version"))
	}
	if s.GetFloat("weather_temperature_c") != 16 || len(conditions.Fields(s)) != 19 {
		t.Errorf("values not written: %v / %v", s.GetFloat("weather_temperature_c"), conditions.Fields(s))
	}
	if !s.GetDateTime("conditions_queried_for").Time().Equal(time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC)) {
		t.Errorf("queried_for = %v", s.Get("conditions_queried_for"))
	}
	if !s.GetDateTime("conditions_fetched_at").Time().Equal(condNow) {
		t.Errorf("fetched_at = %v", s.Get("conditions_fetched_at"))
	}
	if n := tempusRows(t, app, sampleID); n != 6 {
		t.Errorf("tempus rows = %d, want 6", n)
	}
	if got := f.datetimes; len(got) != 1 || got[0] != "2026-05-19T15:00:00Z" {
		t.Errorf("asked for %v", got)
	}
}

func TestEnrich_SecondRunDoesNotBumpVersion(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	// One hour after the sample: provisional, so a second run asks again.
	e := newConditionsEnricher(app, f, time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	e.EnrichSample(context.Background(), sampleID)
	first := loadSample(t, app, sampleID)
	if first.GetString("conditions_status") != conditions.StatusProvisional || first.GetInt("version") != 4 {
		t.Fatalf("status %q, version %d", first.GetString("conditions_status"), first.GetInt("version"))
	}
	e.refreshSample(context.Background(), sampleID)
	second := loadSample(t, app, sampleID)
	if second.GetInt("version") != 4 {
		t.Errorf("version = %d after an identical answer, want 4", second.GetInt("version"))
	}
	if f.hits() != 2 {
		t.Errorf("tempus hits = %d, want 2", f.hits())
	}
}

func TestEnrich_TempusDownLeavesPending(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	f.fail = true
	newConditionsEnricher(app, f, condNow).EnrichSample(context.Background(), sampleID)
	s := loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusPending || s.GetInt("version") != 3 {
		t.Errorf("status %q, version %d", s.GetString("conditions_status"), s.GetInt("version"))
	}
}

// A pending sample has no valid values; features of its former
// coordinate must not outlive a failed query.
func TestEnrich_TempusDownRemovesStaleFeatures(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := pendingSample(t, app)
	if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeTempus,
		[]geoplace.Feature{{SourceID: "tempus:sun", SourceName: "Tempus", Layer: "sun"}}); err != nil {
		t.Fatal(err)
	}
	f := newFakeTempus(t, "query_past_all_ok.json")
	f.fail = true
	newConditionsEnricher(app, f, condNow).EnrichSample(context.Background(), sampleID)
	if n := tempusRows(t, app, sampleID); n != 0 {
		t.Errorf("stale tempus rows = %d", n)
	}
}

func TestEnrich_KeepsOrtusFeatures(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := pendingSample(t, app)
	if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeOrtus,
		[]geoplace.Feature{{SourceID: "nsg", SourceName: "NSG", Layer: "l", FeatureID: "1"}}); err != nil {
		t.Fatal(err)
	}
	newConditionsEnricher(app, newFakeTempus(t, "query_past_all_ok.json"), condNow).
		EnrichSample(context.Background(), sampleID)
	if all, tempus := len(sampleFeatures(t, app, sampleID)), tempusRows(t, app, sampleID); all != 7 || tempus != 6 {
		t.Errorf("features = %d, tempus = %d", all, tempus)
	}
}

func TestEnrich_SkipsFinalEmptyStatusAndNoCoordinate(t *testing.T) {
	app := newAppForRecordsOnly(t)
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)

	ownerID, final, ftID := pendingSample(t, app)
	updateSample(t, app, final, map[string]any{"conditions_status": conditions.StatusFinal})
	e.EnrichSample(context.Background(), final)

	legacy := extraSample(t, app, ownerID, ftID) // status empty
	e.EnrichSample(context.Background(), legacy)

	noCoord := extraSample(t, app, ownerID, ftID)
	updateSample(t, app, noCoord, map[string]any{
		"conditions_status": conditions.StatusPending, "latitude": 0, "longitude": 0,
	})
	e.EnrichSample(context.Background(), noCoord)

	e.EnrichSample(context.Background(), "doesnotexist00")
	if f.hits() != 0 {
		t.Errorf("tempus hits = %d, want 0", f.hits())
	}
}

func TestEnrich_NilTempusDoesNothing(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	(&ConditionsEnricher{App: app}).EnrichSample(context.Background(), sampleID)
	if s := loadSample(t, app, sampleID); s.GetString("conditions_status") != conditions.StatusPending {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
}

func TestEnrich_AllDayNightUses22Local(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := pendingSample(t, app)
	updateSample(t, app, sampleID, map[string]any{
		"is_all_day": true, "begin_date": time.Date(2026, 5, 18, 22, 0, 0, 0, time.UTC),
	})
	ft, err := app.FindRecordById("fieldtrips", ftID)
	if err != nil {
		t.Fatal(err)
	}
	ft.Set("night_fieldtrip", true)
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	f := newFakeTempus(t, "query_past_all_ok.json")
	newConditionsEnricher(app, f, condNow).EnrichSample(context.Background(), sampleID)
	if got := f.datetimes; len(got) != 1 || got[0] != "2026-05-19T20:00:00Z" {
		t.Errorf("asked for %v, want 22:00 Berlin", got)
	}
}

// The coordinate moves while Tempus is being asked: the answer belongs
// to the old place and must not be written.
func TestEnrich_SkipsWhenCoordinateMovedMeanwhile(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	e.afterQuery = func() {
		updateSample(t, app, sampleID, map[string]any{"latitude": 50.0})
	}
	e.EnrichSample(context.Background(), sampleID)
	s := loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusPending || tempusRows(t, app, sampleID) != 0 {
		t.Errorf("answer for the old coordinate was written: status %q", s.GetString("conditions_status"))
	}
}

func TestEnrich_PanicIsRecovered(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	e := newConditionsEnricher(app, newFakeTempus(t, "query_past_all_ok.json"), condNow)
	e.afterQuery = func() { panic("boom") }
	e.runSafely(sampleID) // must not propagate
	if s := loadSample(t, app, sampleID); s.GetString("conditions_status") != conditions.StatusPending {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
}

func mustSample(t *testing.T, app core.App, id string) *core.Record {
	t.Helper()
	rec, err := app.FindRecordById("samples", id)
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

// --- refresh job ---

func provisionalSample(t *testing.T, app *tests.TestApp, retryAt time.Time) string {
	t.Helper()
	_, id, _ := pendingSample(t, app)
	makeProvisional(t, app, id, retryAt)
	return id
}

func makeProvisional(t *testing.T, app *tests.TestApp, id string, retryAt time.Time) {
	t.Helper()
	rec := mustSample(t, app, id)
	conditions.Apply(rec, conditions.Result{
		Status:     conditions.StatusProvisional,
		QueriedFor: time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC),
		FetchedAt:  time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC),
		RetryAt:    retryAt,
		Values:     map[string]any{"weather_temperature_c": 11.0},
	})
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatal(err)
	}
}

func TestRefreshDue_PicksProvisionalPastRetryAt(t *testing.T) {
	app := newAppForRecordsOnly(t)
	id := provisionalSample(t, app, condNow.Add(-time.Minute))
	f := newFakeTempus(t, "query_past_all_ok.json")
	n := newConditionsEnricher(app, f, condNow).RefreshDue(context.Background(), 10)
	s := loadSample(t, app, id)
	// The values the app once delivered are replaced by the final ones.
	if n != 1 || s.GetString("conditions_status") != conditions.StatusFinal || s.GetFloat("weather_temperature_c") != 16 {
		t.Errorf("n = %d, status %q, temperature %v", n, s.GetString("conditions_status"), s.GetFloat("weather_temperature_c"))
	}
}

func TestRefreshDue_SkipsProvisionalBeforeRetryAt(t *testing.T) {
	app := newAppForRecordsOnly(t)
	provisionalSample(t, app, condNow.Add(time.Hour))
	f := newFakeTempus(t, "query_past_all_ok.json")
	if n := newConditionsEnricher(app, f, condNow).RefreshDue(context.Background(), 10); n != 0 || f.hits() != 0 {
		t.Errorf("n = %d, hits = %d", n, f.hits())
	}
}

func TestRefreshDue_PicksStalePendingSkipsFreshOne(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, id, _ := pendingSample(t, app) // row was just saved
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, time.Now().UTC())
	if n := e.RefreshDue(context.Background(), 10); n != 0 {
		t.Errorf("fresh pending sample picked (n = %d): the create hook is still working on it", n)
	}
	e.Now = func() time.Time { return time.Now().UTC().Add(2 * time.Hour) }
	if n := e.RefreshDue(context.Background(), 10); n != 1 {
		t.Errorf("stale pending sample not picked (n = %d)", n)
	}
	if s := loadSample(t, app, id); s.GetString("conditions_status") == conditions.StatusPending {
		t.Error("sample still pending")
	}
}

func TestRefreshDue_NeverTouchesEmptyStatusOrMissingCoordinate(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, noCoord, ftID := pendingSample(t, app)
	updateSample(t, app, noCoord, map[string]any{"latitude": 0, "longitude": 0})
	extraSample(t, app, ownerID, ftID) // legacy row, status empty
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, time.Now().UTC().Add(48*time.Hour))
	if n := e.RefreshDue(context.Background(), 10); n != 0 || f.hits() != 0 {
		t.Errorf("n = %d, hits = %d", n, f.hits())
	}
}

func TestRefreshDue_RespectsLimit(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, first, ftID := pendingSample(t, app)
	makeProvisional(t, app, first, condNow.Add(-time.Minute))
	for i := 0; i < 2; i++ {
		makeProvisional(t, app, extraSample(t, app, ownerID, ftID), condNow.Add(-time.Duration(i+2)*time.Minute))
	}
	f := newFakeTempus(t, "query_past_all_ok.json")
	if n := newConditionsEnricher(app, f, condNow).RefreshDue(context.Background(), 2); n != 2 || f.hits() != 2 {
		t.Errorf("n = %d, hits = %d, want 2", n, f.hits())
	}
}

func TestRefreshDue_NilTempusDoesNothing(t *testing.T) {
	app := newAppForRecordsOnly(t)
	provisionalSample(t, app, condNow.Add(-time.Minute))
	if n := (&ConditionsEnricher{App: app}).RefreshDue(context.Background(), 10); n != 0 {
		t.Errorf("n = %d", n)
	}
}

// While Tempus is failing slowly, the app delivers its own values and
// features. The error path must not delete them.
func TestEnrich_FailedQueryKeepsFeaturesDeliveredMeanwhile(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	f.fail = true
	e := newConditionsEnricher(app, f, condNow)
	e.afterQuery = func() {
		rec := mustSample(t, app, sampleID)
		conditions.Apply(rec, conditions.Result{
			Status:     conditions.StatusFinal,
			QueriedFor: time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC),
			FetchedAt:  condNow,
			Values:     map[string]any{"weather_temperature_c": 12.0},
		})
		if err := app.SaveNoValidate(rec); err != nil {
			t.Fatal(err)
		}
		if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeTempus,
			[]geoplace.Feature{{SourceID: "tempus:weather", SourceName: "Tempus", Layer: "weather"}}); err != nil {
			t.Fatal(err)
		}
	}
	e.EnrichSample(context.Background(), sampleID)
	if n := tempusRows(t, app, sampleID); n != 1 {
		t.Errorf("tempus rows = %d: the app's features were deleted", n)
	}
}

// Ortus corrects the zone of an all-day sample: 14:00 local is another
// instant now, the stored values belong to the old one.
func TestOrtusTimezoneChange_ResetsConditionsAndAsksAgain(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{
		"location_status": "pending", "timezone": "UTC", "timezone_source": "device",
		"is_all_day": true, "begin_date": time.Date(2026, 5, 19, 0, 0, 0, 0, time.UTC),
	})
	rec := mustSample(t, app, sampleID)
	conditions.Apply(rec, conditions.Result{
		Status:     conditions.StatusFinal,
		QueriedFor: time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC),
		FetchedAt:  condNow,
		Values:     map[string]any{"weather_temperature_c": 12.0},
	})
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatal(err)
	}

	tempus := newFakeTempus(t, "query_past_all_ok.json")
	e := newOrtusEnricher(app, newFakeOrtus(t, "query_de_ochsenfurt.json"))

	// Without a conditions enricher the values are at least cleared.
	runEnrich(t, e, sampleID)
	s := loadSample(t, app, sampleID)
	if s.GetString("timezone") != "Europe/Berlin" {
		t.Fatalf("precondition: timezone = %q", s.GetString("timezone"))
	}
	if s.GetString("conditions_status") != conditions.StatusPending || s.GetFloat("weather_temperature_c") != 0 {
		t.Errorf("status %q, temperature %v after the zone change", s.GetString("conditions_status"), s.GetFloat("weather_temperature_c"))
	}

	// With one, the sample is asked again right away, for 14:00 Berlin.
	e.Conditions = newConditionsEnricher(app, tempus, condNow)
	e.runSafely(sampleID, "")
	s = loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusFinal {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
	if got := tempus.datetimes; len(got) != 1 || got[0] != "2026-05-19T12:00:00Z" {
		t.Errorf("asked for %v, want 14:00 Berlin", got)
	}
}

// Two triggers for the same sample (create hook and the Ortus run) must
// not both ask Tempus.
func TestEnrich_ConcurrentRunsForOneSampleQueryOnce(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e.EnrichSample(context.Background(), sampleID)
		}()
	}
	wg.Wait()
	if f.hits() != 1 {
		t.Errorf("tempus hits = %d, want 1", f.hits())
	}
}

// A sample that lost its coordinate has no conditions; the feature rows
// of its former place must go as well.
func TestCoordinateRemoved_DropsTempusFeatures(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := pendingSample(t, app)
	for scope, fs := range map[geoplace.FeatureScope][]geoplace.Feature{
		geoplace.ScopeTempus: {{SourceID: "tempus:sun", SourceName: "Tempus", Layer: "sun"}},
		geoplace.ScopeOrtus:  {{SourceID: "nsg", SourceName: "NSG", Layer: "l", FeatureID: "1"}},
	} {
		if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, scope, fs); err != nil {
			t.Fatal(err)
		}
	}
	e := newConditionsEnricher(app, newFakeTempus(t, "query_past_all_ok.json"), condNow)

	// With a coordinate nothing is removed.
	e.dropFeaturesOfUnaskable(sampleID)
	if n := tempusRows(t, app, sampleID); n != 1 {
		t.Fatalf("tempus rows = %d, want 1 while the coordinate exists", n)
	}
	updateSample(t, app, sampleID, map[string]any{"latitude": 0, "longitude": 0, "conditions_status": ""})
	e.dropFeaturesOfUnaskable(sampleID)
	if tempus, all := tempusRows(t, app, sampleID), len(sampleFeatures(t, app, sampleID)); tempus != 0 || all != 1 {
		t.Errorf("tempus rows = %d, all rows = %d; want 0 and the Ortus row", tempus, all)
	}
}

// The timezone backfill corrects zones too; conditions of an all-day
// sample queried for the old zone's 14:00 must not survive it.
func TestEnrichSampleTimezone_ResetsConditionsOfAllDaySample(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{
		"location_status": "manual", "timezone": "UTC", "timezone_source": "device",
		"is_all_day": true, "begin_date": time.Date(2026, 5, 19, 0, 0, 0, 0, time.UTC),
	})
	rec := mustSample(t, app, sampleID)
	conditions.Apply(rec, conditions.Result{
		Status:     conditions.StatusFinal,
		QueriedFor: time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC),
		FetchedAt:  condNow,
		Values:     map[string]any{"weather_temperature_c": 12.0},
	})
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatal(err)
	}
	e := newOrtusEnricher(app, newFakeOrtus(t, "query_de_ochsenfurt.json"))
	saved, err := e.EnrichSampleTimezone(context.Background(), sampleID)
	if err != nil || !saved {
		t.Fatalf("saved = %v, err = %v", saved, err)
	}
	s := loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusPending || s.GetFloat("weather_temperature_c") != 0 {
		t.Errorf("status %q, temperature %v", s.GetString("conditions_status"), s.GetFloat("weather_temperature_c"))
	}
}

// The hooks and the Ortus follow-up fill pending samples only. A
// provisional one (e.g. values the app delivered) waits for its retry
// date and the refresh job.
func TestEnrich_LeavesProvisionalToTheRefreshJob(t *testing.T) {
	app := newAppForRecordsOnly(t)
	id := provisionalSample(t, app, condNow.Add(time.Hour))
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	e.EnrichSample(context.Background(), id)
	if f.hits() != 0 {
		t.Errorf("tempus hits = %d: a provisional sample was asked before its retry date", f.hits())
	}
	if s := loadSample(t, app, id); s.GetFloat("weather_temperature_c") != 11 {
		t.Errorf("temperature = %v, the delivered value was overwritten", s.GetFloat("weather_temperature_c"))
	}
}

// The app stores its own answer while ours is in flight: theirs is
// newer and stays.
func TestEnrich_SkipsWriteWhenConditionsChangedMeanwhile(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	e.afterQuery = func() { makeProvisional(t, app, sampleID, condNow.Add(time.Hour)) }
	e.EnrichSample(context.Background(), sampleID)
	s := loadSample(t, app, sampleID)
	if s.GetString("conditions_status") != conditions.StatusProvisional || s.GetFloat("weather_temperature_c") != 11 {
		t.Errorf("status %q, temperature %v: the answer in flight overwrote newer values",
			s.GetString("conditions_status"), s.GetFloat("weather_temperature_c"))
	}
	if n := tempusRows(t, app, sampleID); n != 0 {
		t.Errorf("tempus rows = %d, want none from the skipped answer", n)
	}
}

// The app saves provisional values right after the backfill marked the
// sample: the backfill must not ask Tempus and overwrite them.
func TestBackfillSample_KeepsValuesSavedAfterTheMark(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := legacySampleWithHeight(t, app) // status empty
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	e.afterBackfillMark = func() { makeProvisional(t, app, sampleID, condNow.Add(time.Hour)) }
	if e.BackfillSample(context.Background(), sampleID) {
		t.Error("reported as queried although Tempus was never asked")
	}
	s := loadSample(t, app, sampleID)
	if f.hits() != 0 || s.GetFloat("weather_temperature_c") != 11 {
		t.Errorf("tempus hits = %d, temperature %v: the app's provisional values were overwritten",
			f.hits(), s.GetFloat("weather_temperature_c"))
	}
}

func TestBackfillSample_FillsLegacySampleAndSkipsOthers(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, legacy, ftID := legacySampleWithHeight(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	e := newConditionsEnricher(app, f, condNow)
	if !e.BackfillSample(context.Background(), legacy) {
		t.Fatal("legacy sample not processed")
	}
	if s := loadSample(t, app, legacy); s.GetString("conditions_status") != conditions.StatusFinal {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
	if e.BackfillSample(context.Background(), legacy) {
		t.Error("a processed sample was taken again")
	}
	noCoord := extraSample(t, app, ownerID, ftID)
	updateSample(t, app, noCoord, map[string]any{"latitude": 0, "longitude": 0})
	if e.BackfillSample(context.Background(), noCoord) || e.BackfillSample(context.Background(), "doesnotexist00") {
		t.Error("a sample without coordinate or a missing one was processed")
	}
	if f.hits() != 1 {
		t.Errorf("tempus hits = %d, want 1", f.hits())
	}
}

// A failed query still counts as an attempt.
func TestBackfillSample_FailedQueryCountsAsQueried(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := legacySampleWithHeight(t, app)
	f := newFakeTempus(t, "query_past_all_ok.json")
	f.fail = true
	if !newConditionsEnricher(app, f, condNow).BackfillSample(context.Background(), sampleID) {
		t.Error("a failed Tempus query was not counted")
	}
}

// Tempus needs the height of the place. A sample without one is not
// asked and stays pending until the GPS or Ortus delivers a height.
func TestEnrich_WithoutElevationStaysPendingAndAsksNothing(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	updateSample(t, app, sampleID, map[string]any{"elevation": 0, "elevation_source": ""})
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	newConditionsEnricher(app, tempus, condNow).EnrichSample(context.Background(), sampleID)
	if tempus.hits() != 0 {
		t.Errorf("tempus asked %d times without a height", tempus.hits())
	}
	if got := loadSample(t, app, sampleID).GetString("conditions_status"); got != conditions.StatusPending {
		t.Errorf("status = %q, want pending", got)
	}
}

func TestEnrich_SendsTheSampleElevation(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	newConditionsEnricher(app, tempus, condNow).EnrichSample(context.Background(), sampleID)
	if got := tempus.elevations; len(got) != 1 || got[0] != "520" {
		t.Errorf("elevations = %v, want [520]", got)
	}
}

func TestRefreshDue_SkipsPendingWithoutElevation(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	updateSample(t, app, sampleID, map[string]any{"elevation": 0, "elevation_source": ""})
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	// Two hours on, the row counts as a pending one left behind.
	later := time.Now().UTC().Add(2 * time.Hour)
	if n := newConditionsEnricher(app, tempus, later).RefreshDue(context.Background(), 10); n != 0 {
		t.Errorf("queried = %d, want 0", n)
	}
}

// The backfill leaves a legacy sample without height unmarked, so a
// later run picks it up once a height is there.
func TestBackfillSample_LeavesSampleWithoutElevationUnmarked(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, _, ftID := pendingSample(t, app)
	legacy := extraSample(t, app, ownerID, ftID)
	updateSample(t, app, legacy, map[string]any{"elevation": 0, "elevation_source": ""})
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	if newConditionsEnricher(app, tempus, condNow).BackfillSample(context.Background(), legacy) {
		t.Error("backfill reported a query")
	}
	if got := loadSample(t, app, legacy).GetString("conditions_status"); got != "" {
		t.Errorf("status = %q, want empty", got)
	}
}

// The Ortus run replaces the DEM height: values queried for the old
// height no longer fit and are asked again with the new one.
func TestOrtusDEMHeightChange_ResetsConditionsAndAsksAgain(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := createOwnerSampleFieldtrip(t, app, deLat, deLon)
	updateSample(t, app, sampleID, map[string]any{
		"location_status": "pending", "timezone": "Europe/Berlin", "timezone_source": "location_service",
		"elevation": 2000, "elevation_source": "backend_service",
	})
	rec := mustSample(t, app, sampleID)
	conditions.Apply(rec, conditions.Result{
		Status:     conditions.StatusFinal,
		QueriedFor: time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC),
		FetchedAt:  condNow,
		Values:     map[string]any{"weather_temperature_c": 12.0},
	})
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatal(err)
	}
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	e := newOrtusEnricher(app, newFakeOrtus(t, "query_de_ochsenfurt.json"))
	e.Conditions = newConditionsEnricher(app, tempus, condNow)
	e.runSafely(sampleID, "")

	s := loadSample(t, app, sampleID)
	if s.GetFloat("elevation") == 2000 {
		t.Fatal("precondition: the Ortus run did not replace the DEM height")
	}
	want := strconv.Itoa(int(math.Round(s.GetFloat("elevation"))))
	if got := tempus.elevations; len(got) != 1 || got[0] != want {
		t.Errorf("asked with elevations %v, want [%s]", got, want)
	}
	if s.GetString("conditions_status") != conditions.StatusFinal {
		t.Errorf("status = %q", s.GetString("conditions_status"))
	}
}

// legacySampleWithHeight is a sample from before Phase T (empty
// conditions status) that has what Tempus requires: a height.
func legacySampleWithHeight(t *testing.T, app *tests.TestApp) (ownerID, sampleID, ftID string) {
	t.Helper()
	ownerID, sampleID, ftID = createOwnerSampleFieldtrip(t, app, 48.1351, 11.582)
	updateSample(t, app, sampleID, map[string]any{"elevation": 519.6, "elevation_source": "location_service"})
	return
}

// Without a usable height the hook left the sample pending and without
// values; the feature rows of the earlier answer must go as well, or
// they stay for as long as no height arrives.
func TestEnrich_WithoutElevationRemovesStaleFeatures(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, sampleID, _ := pendingSample(t, app)
	if err := geoplace.ReplaceFeatures(app, sampleID, ownerID, geoplace.ScopeTempus,
		[]geoplace.Feature{{SourceID: "tempus:sun", SourceName: "Tempus", Layer: "sun"}}); err != nil {
		t.Fatal(err)
	}
	updateSample(t, app, sampleID, map[string]any{"elevation": 0, "elevation_source": ""})
	newConditionsEnricher(app, newFakeTempus(t, "query_past_all_ok.json"), condNow).
		EnrichSample(context.Background(), sampleID)
	if n := tempusRows(t, app, sampleID); n != 0 {
		t.Errorf("tempus rows = %d, want 0", n)
	}
}

// A height Tempus does not accept must not use up the limit of every
// run in front of samples that can be asked.
func TestRefreshDue_UnusableHeightDoesNotBlockTheOthers(t *testing.T) {
	app := newAppForRecordsOnly(t)
	ownerID, tooHigh, ftID := pendingSample(t, app)
	updateSample(t, app, tooHigh, map[string]any{"elevation": 9500})
	ok := extraSample(t, app, ownerID, ftID)
	updateSample(t, app, ok, map[string]any{"conditions_status": conditions.StatusPending})
	tempus := newFakeTempus(t, "query_past_all_ok.json")
	later := time.Now().UTC().Add(2 * time.Hour)
	if n := newConditionsEnricher(app, tempus, later).RefreshDue(context.Background(), 1); n != 1 {
		t.Fatalf("queried = %d, want 1", n)
	}
	if tempus.hits() != 1 || loadSample(t, app, ok).GetString("conditions_status") == conditions.StatusPending {
		t.Errorf("hits = %d, status of the usable sample = %q", tempus.hits(), loadSample(t, app, ok).GetString("conditions_status"))
	}
}

// After a coordinate move the DEM height still belongs to the old
// place. The Ortus run that follows the move asks Tempus itself, with
// the height it found; the update's own trigger waits for it.
func TestWaitsForOrtusHeight(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, _ := pendingSample(t, app)
	for _, c := range []struct {
		name   string
		source string
		moveBy float64
		want   bool
	}{
		{"DEM height, coordinate moved", "backend_service", 0.01, true},
		{"DEM height, nothing moved", "backend_service", 0, false},
		{"GPS height, coordinate moved", "location_service", 0.01, false},
		{"no height, coordinate moved", "", 0.01, false},
		// No coordinate, no Ortus run: the cleanup must not be skipped.
		{"DEM height, coordinate removed", "backend_service", -48.1351, false},
	} {
		updateSample(t, app, sampleID, map[string]any{"elevation_source": c.source})
		orig := loadSample(t, app, sampleID)
		rec := orig.Clone()
		rec.Set("latitude", rec.GetFloat("latitude")+c.moveBy)
		if c.moveBy < 0 {
			rec.Set("longitude", 0)
		}
		if got := waitsForOrtusHeight(orig, rec); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
