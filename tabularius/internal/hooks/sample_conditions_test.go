package hooks

import (
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/tabularius/internal/conditions"
)

var condBegin = time.Date(2026, 5, 19, 12, 0, 0, 0, time.UTC)

// conditionsSample builds an unsaved sample with a coordinate and a
// time of day, as a create request would deliver it.
func conditionsSample(t *testing.T, app *tests.TestApp) *core.Record {
	t.Helper()
	owner := createTestUser(t, app, "cond"+uniqueSuffix(t)+"@example.com")
	rec := newSampleRecord(t, app)
	rec.Set("owner", owner.Id)
	rec.Set("sample_id", "260519/1")
	rec.Set("latitude", 49.68)
	rec.Set("longitude", 10.03)
	rec.Set("begin_date", condBegin)
	rec.Set("timezone", "Europe/Berlin")
	return rec
}

// clientValues fills the record the way an app that queried Tempus
// itself would: a provisional answer fetched an hour after the instant,
// a final one fetched after the archive became final.
func clientValues(rec *core.Record, queriedFor time.Time, status string) {
	fetched, retry := queriedFor.Add(time.Hour), queriedFor.Add(conditions.FinalAfter)
	if status == conditions.StatusFinal {
		fetched, retry = queriedFor.Add(conditions.FinalAfter+time.Hour), time.Time{}
	}
	conditions.Apply(rec, conditions.Result{
		Status:     status,
		QueriedFor: queriedFor,
		FetchedAt:  fetched,
		RetryAt:    retry,
		Values:     map[string]any{"weather_temperature_c": 18.4},
	})
}

// saved stores rec and returns it freshly loaded, as an update request
// hook sees it (Original() = stored state).
func saved(t *testing.T, app *tests.TestApp, rec *core.Record) *core.Record {
	t.Helper()
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save: %v", err)
	}
	fresh, err := app.FindRecordById("samples", rec.Id)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	return fresh
}

func status(rec *core.Record) string { return rec.GetString("conditions_status") }

func TestReset_CreateWithoutValuesIsPending(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

func TestReset_CreateWithMatchingClientValuesKeepsThem(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusProvisional)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusProvisional || rec.GetFloat("weather_temperature_c") != 18.4 {
		t.Errorf("status %q, temperature %v", status(rec), rec.GetFloat("weather_temperature_c"))
	}
}

func TestReset_CreateWithValuesForOtherInstantIsCleared(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin.Add(-3*time.Hour), conditions.StatusFinal)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusPending || rec.GetFloat("weather_temperature_c") != 0 || len(conditions.Fields(rec)) != 0 {
		t.Errorf("stale client values kept: status %q", status(rec))
	}
}

// All-day: the app has to query for 14:00 local, not for the begin.
func TestReset_CreateAllDayExpects14Local(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	rec.Set("is_all_day", true)
	rec.Set("begin_date", time.Date(2026, 5, 18, 22, 0, 0, 0, time.UTC)) // 19.05. 00:00 Berlin
	clientValues(rec, time.Date(2026, 5, 19, 12, 0, 0, 0, time.UTC), conditions.StatusFinal)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusFinal {
		t.Errorf("14:00 local must match: status %q", status(rec))
	}
	clientValues(rec, rec.GetDateTime("begin_date").Time(), conditions.StatusFinal)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusPending {
		t.Errorf("values for midnight must be cleared: status %q", status(rec))
	}
}

func TestReset_NoCoordinateHasEmptyStatus(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	rec.Set("latitude", 0)
	rec.Set("longitude", 0)
	clientValues(rec, condBegin, conditions.StatusFinal)
	resetStaleConditions(app, rec, true)
	if status(rec) != "" || rec.GetFloat("weather_temperature_c") != 0 {
		t.Errorf("status %q, temperature %v", status(rec), rec.GetFloat("weather_temperature_c"))
	}
}

func TestReset_UpdateCoordinateMovedClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("latitude", 49.70)
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending || rec.GetFloat("weather_temperature_c") != 0 {
		t.Errorf("status %q after the coordinate moved", status(rec))
	}
}

func TestReset_UpdateBeginChangedClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("begin_date", condBegin.Add(2*time.Hour))
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status %q after the begin changed", status(rec))
	}
}

func TestReset_UpdateAllDayToggledClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	// 09:00 UTC: not the 14:00 local an all-day sample is queried for.
	morning := condBegin.Add(-3 * time.Hour)
	rec.Set("begin_date", morning)
	clientValues(rec, morning, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("is_all_day", true)
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status %q after all-day was switched on", status(rec))
	}
}

func TestReset_UpdateNotesOnlyKeepsFinal(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("notes", "Eichenstubben")
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusFinal || rec.GetFloat("weather_temperature_c") != 18.4 {
		t.Errorf("status %q, temperature %v", status(rec), rec.GetFloat("weather_temperature_c"))
	}
}

func TestReset_UpdateWithFreshClientValuesKeepsThem(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	// The app moved the coordinate and queried Tempus again.
	rec.Set("latitude", 49.70)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec.Set("conditions_fetched_at", condBegin.Add(200*time.Hour))
	rec.Set("weather_temperature_c", 21.0)
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusFinal || rec.GetFloat("weather_temperature_c") != 21.0 {
		t.Errorf("fresh client values dropped: status %q", status(rec))
	}
}

// Moved coordinate, but the client only echoes the old values back.
func TestReset_UpdateMovedWithEchoedValuesClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("longitude", 10.20)
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status %q: values of the old coordinate kept", status(rec))
	}
}

// Rows from before Phase T are filled by the backfill only.
func TestReset_LegacySampleWithEmptyStatusStaysEmptyOnNotesUpdate(t *testing.T) {
	app := setupTestApp(t)
	rec := saved(t, app, conditionsSample(t, app))
	rec.Set("notes", "nachgetragen")
	resetStaleConditions(app, rec, false)
	if status(rec) != "" {
		t.Errorf("status = %q, want empty", status(rec))
	}
}

func TestReset_UpdatePendingStaysPending(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	conditions.Clear(rec)
	rec = saved(t, app, rec)
	rec.Set("notes", "x")
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

// Unchanged place and time, but the client sends values for another
// instant: they are not taken over.
func TestReset_UpdateWithMismatchingClientValuesClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	clientValues(rec, condBegin.Add(-24*time.Hour), conditions.StatusFinal)
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

func TestSampleQueryInstant_UsesNightFlagOfFieldtrip(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	rec.Set("is_all_day", true)
	rec.Set("begin_date", time.Date(2026, 5, 18, 22, 0, 0, 0, time.UTC))
	if got := SampleQueryInstant(app, rec); !got.Equal(time.Date(2026, 5, 19, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("without fieldtrip: %s", got)
	}
	coll, _ := app.FindCollectionByNameOrId("fieldtrips")
	ft := core.NewRecord(coll)
	ft.Set("owner", rec.GetString("owner"))
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("night_fieldtrip", true)
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	rec.Set("fieldtrip", ft.Id)
	if got := SampleQueryInstant(app, rec); !got.Equal(time.Date(2026, 5, 19, 20, 0, 0, 0, time.UTC)) {
		t.Errorf("night fieldtrip: %s", got)
	}
}

// nightFlipFixture stores a fieldtrip with one all-day and one timed
// sample, both with final values for their instant, and registers the
// hooks.
func nightFlipFixture(t *testing.T, app *tests.TestApp) (ft, allDay, timed *core.Record) {
	t.Helper()
	RegisterSampleConditionsReset(app)
	owner := createTestUser(t, app, "night"+uniqueSuffix(t)+"@example.com")
	coll, _ := app.FindCollectionByNameOrId("fieldtrips")
	ft = core.NewRecord(coll)
	ft.Set("owner", owner.Id)
	ft.Set("collecting_day", "2026-05-19")
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	mk := func(allDay bool, begin time.Time) *core.Record {
		rec := newSampleRecord(t, app)
		rec.Set("owner", owner.Id)
		rec.Set("fieldtrip", ft.Id)
		rec.Set("latitude", 49.68)
		rec.Set("longitude", 10.03)
		rec.Set("timezone", "Europe/Berlin")
		rec.Set("is_all_day", allDay)
		rec.Set("begin_date", begin)
		rec.Set("version", 5)
		clientValues(rec, SampleQueryInstant(app, rec), conditions.StatusFinal)
		return saved(t, app, rec)
	}
	allDay = mk(true, time.Date(2026, 5, 18, 22, 0, 0, 0, time.UTC))
	timed = mk(false, condBegin)
	return ft, allDay, timed
}

func reload(t *testing.T, app *tests.TestApp, rec *core.Record) *core.Record {
	t.Helper()
	fresh, err := app.FindRecordById(rec.Collection().Name, rec.Id)
	if err != nil {
		t.Fatal(err)
	}
	return fresh
}

// A fieldtrip turning into a night fieldtrip moves the instant of its
// all-day samples from 14:00 to 22:00: their values no longer fit.
func TestNightFlagFlip_ResetsAllDaySamples(t *testing.T) {
	app := setupTestApp(t)
	ft, allDay, _ := nightFlipFixture(t, app)
	ft = reload(t, app, ft)
	ft.Set("night_fieldtrip", true)
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, allDay)
	if status(got) != conditions.StatusPending || got.GetFloat("weather_temperature_c") != 0 {
		t.Errorf("status %q, temperature %v", status(got), got.GetFloat("weather_temperature_c"))
	}
	if got.GetInt("version") != 6 {
		t.Errorf("version = %d, want 6", got.GetInt("version"))
	}
}

func TestNightFlagFlip_LeavesTimedSamples(t *testing.T) {
	app := setupTestApp(t)
	ft, _, timed := nightFlipFixture(t, app)
	ft = reload(t, app, ft)
	ft.Set("night_fieldtrip", true)
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, timed)
	if status(got) != conditions.StatusFinal || got.GetInt("version") != 5 {
		t.Errorf("status %q, version %d", status(got), got.GetInt("version"))
	}
}

func TestFieldtripSaveWithoutNightChange_LeavesSamples(t *testing.T) {
	app := setupTestApp(t)
	ft, allDay, _ := nightFlipFixture(t, app)
	ft = reload(t, app, ft)
	ft.Set("title", "Mainaue")
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	if got := reload(t, app, allDay); status(got) != conditions.StatusFinal || got.GetInt("version") != 5 {
		t.Errorf("status %q, version %d", status(got), got.GetInt("version"))
	}
}

// --- what a client says about its own values is checked, not trusted ---

func retryAt(rec *core.Record) time.Time { return rec.GetDateTime("conditions_retry_at").Time() }

// "final" for forecast data would never be replaced by the archive.
func TestReset_ClientFinalForFreshInstantBecomesProvisional(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusProvisional)
	rec.Set("conditions_status", conditions.StatusFinal)
	rec.Set("conditions_retry_at", "")
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusProvisional || !retryAt(rec).Equal(condBegin.Add(conditions.FinalAfter)) {
		t.Errorf("status %q, retry %s", status(rec), retryAt(rec))
	}
	if rec.GetFloat("weather_temperature_c") != 18.4 {
		t.Error("the values themselves must be kept")
	}
}

// Without a retry date the refresh job would never pick the sample up.
func TestReset_ClientProvisionalWithoutRetryGetsOne(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusProvisional)
	rec.Set("conditions_retry_at", "")
	resetStaleConditions(app, rec, true)
	if !retryAt(rec).Equal(condBegin.Add(conditions.FinalAfter)) {
		t.Errorf("retry = %s", retryAt(rec))
	}
}

func TestReset_ClientRetryFarInFutureIsBounded(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusProvisional)
	rec.Set("conditions_retry_at", condBegin.Add(10*365*24*time.Hour))
	resetStaleConditions(app, rec, true)
	if !retryAt(rec).Equal(condBegin.Add(conditions.FinalAfter)) {
		t.Errorf("retry = %s", retryAt(rec))
	}
}

// A sooner retry (a provider was unavailable) is the client's to say.
func TestReset_ClientEarlierRetryIsKept(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusProvisional)
	soon := condBegin.Add(3 * time.Hour)
	rec.Set("conditions_retry_at", soon)
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusProvisional || !retryAt(rec).Equal(soon) {
		t.Errorf("status %q, retry %s", status(rec), retryAt(rec))
	}
}

func TestReset_ClientFinalAfterFiveDaysStaysFinalWithoutRetry(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec.Set("conditions_retry_at", condBegin.Add(999*time.Hour))
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusFinal || !retryAt(rec).IsZero() {
		t.Errorf("status %q, retry %s", status(rec), retryAt(rec))
	}
}

func TestReset_ClientValuesWithoutFetchDateAreCleared(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec.Set("conditions_fetched_at", "")
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

func TestReset_ClientValuesFetchedInTheFutureAreCleared(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec.Set("conditions_fetched_at", time.Now().Add(48*time.Hour))
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

// A sample planned for later: only sun and moon exist yet.
func TestReset_ClientValuesForFutureInstantRetrySoonAfterIt(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	future := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Second)
	rec.Set("begin_date", future)
	clientValues(rec, future, conditions.StatusProvisional)
	rec.Set("conditions_fetched_at", time.Now().UTC().Add(-time.Minute))
	rec.Set("conditions_retry_at", "")
	resetStaleConditions(app, rec, true)
	if status(rec) != conditions.StatusProvisional || !retryAt(rec).Equal(future.Add(time.Hour)) {
		t.Errorf("status %q, retry %s", status(rec), retryAt(rec))
	}
}

// After a move the client must have fetched anew: a fetch date older
// than the stored one is an echo, however it differs.
func TestReset_UpdateMovedWithOlderFetchDateClears(t *testing.T) {
	app := setupTestApp(t)
	rec := conditionsSample(t, app)
	clientValues(rec, condBegin, conditions.StatusFinal)
	rec = saved(t, app, rec)
	rec.Set("latitude", 49.70)
	rec.Set("conditions_fetched_at", condBegin.Add(conditions.FinalAfter))
	resetStaleConditions(app, rec, false)
	if status(rec) != conditions.StatusPending {
		t.Errorf("status = %q", status(rec))
	}
}

// The reset re-reads each sample inside its transaction: a row that was
// changed after the list was read is judged by its current state.
func TestResetAllDayConditions_JudgesTheCurrentRow(t *testing.T) {
	app := setupTestApp(t)
	ft, allDay, _ := nightFlipFixture(t, app)
	ft = reload(t, app, ft)
	ft.Set("night_fieldtrip", true)
	// Saved without the hook's knowledge of what follows: by the time
	// the reset runs, the sample is no longer all-day.
	beforeResetSave = func(id string) {
		if id != allDay.Id {
			return
		}
		rec := reload(t, app, allDay)
		rec.Set("is_all_day", false)
		rec.Set("begin_date", condBegin)
		clientValues(rec, condBegin, conditions.StatusFinal)
		rec.Set("version", 9)
		if err := app.SaveNoValidate(rec); err != nil {
			t.Fatal(err)
		}
	}
	defer func() { beforeResetSave = nil }()
	if err := app.SaveNoValidate(ft); err != nil {
		t.Fatal(err)
	}
	got := reload(t, app, allDay)
	if status(got) != conditions.StatusFinal || got.GetInt("version") != 9 {
		t.Errorf("status %q, version %d: a stale copy was written over the newer row", status(got), got.GetInt("version"))
	}
}

// A sample deleted between the list and its transaction is skipped; the
// other samples of the fieldtrip are still reset.
func TestResetAllDayConditions_SkipsSampleDeletedMeanwhile(t *testing.T) {
	app := setupTestApp(t)
	ft, allDay, _ := nightFlipFixture(t, app)
	second := newSampleRecord(t, app)
	for _, f := range []string{"owner", "fieldtrip", "latitude", "longitude", "timezone", "is_all_day", "begin_date"} {
		second.Set(f, allDay.Get(f))
	}
	clientValues(second, SampleQueryInstant(app, second), conditions.StatusFinal)
	second = saved(t, app, second)

	deleted := false
	beforeResetSave = func(string) {
		if deleted {
			return
		}
		deleted = true
		if err := app.Delete(reload(t, app, allDay)); err != nil {
			t.Fatal(err)
		}
	}
	defer func() { beforeResetSave = nil }()

	if err := resetAllDayConditionsAfterFlip(t, app, ft); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if got := reload(t, app, second); status(got) != conditions.StatusPending {
		t.Errorf("status of the remaining sample = %q, want pending", status(got))
	}
}

// resetAllDayConditionsAfterFlip flips the night flag in the database
// without the hook and calls the reset directly, so its error shows.
func resetAllDayConditionsAfterFlip(t *testing.T, app *tests.TestApp, ft *core.Record) error {
	t.Helper()
	if _, err := app.DB().NewQuery("UPDATE fieldtrips SET night_fieldtrip = TRUE WHERE id = {:id}").
		Bind(map[string]any{"id": ft.Id}).Execute(); err != nil {
		t.Fatal(err)
	}
	return resetAllDayConditions(app, ft.Id)
}
