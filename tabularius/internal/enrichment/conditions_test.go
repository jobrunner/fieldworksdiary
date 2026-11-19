package enrichment

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	if s.GetFloat("weather_temperature_c") != 16 || len(conditions.Kinds(s)) != 6 {
		t.Errorf("values not written: %v / %v", s.GetFloat("weather_temperature_c"), conditions.Kinds(s))
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
	e.EnrichSample(context.Background(), sampleID)
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
		Kinds:      []string{"weather"},
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
