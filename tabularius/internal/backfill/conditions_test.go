package backfill

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/tabularius/internal/conditions"
	"go.mett.io/tabularius/internal/enrichment"
	"go.mett.io/tabularius/internal/services"
)

// tempusFake serves one recorded answer and counts the requests.
type tempusFake struct {
	srv  *httptest.Server
	hits atomic.Int32
	fail atomic.Bool
	// onHit runs for every request (tests).
	onHit func(n int32)
}

func newTempusFake(t *testing.T) *tempusFake {
	t.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "tempus", "query_past_all_ok.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	f := &tempusFake{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := f.hits.Add(1)
		if f.onHit != nil {
			f.onHit(n)
		}
		if f.fail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func newConditionsRunner(app *tests.TestApp, f *tempusFake, limit int) *ConditionsRunner {
	return &ConditionsRunner{
		App: app,
		Conditions: &enrichment.ConditionsEnricher{
			App: app,
			Tempus: &services.Tempus{
				BaseURL: f.srv.URL, HTTPClient: &http.Client{Timeout: 2 * time.Second}, MaxRetries: 1,
			},
			Timeout: 5 * time.Second,
			// Long after the samples (2026-05-19): answers are final.
			Now: func() time.Time { return time.Date(2026, 8, 1, 9, 0, 0, 0, time.UTC) },
		},
		Limit:    limit,
		Interval: time.Millisecond,
	}
}

func condStatus(t *testing.T, app *tests.TestApp, id string) string {
	t.Helper()
	return reload(t, app, "samples", id).GetString("conditions_status")
}

func TestConditionsRunner_RespectsLimitAndResumes(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	ids := []string{}
	for _, sid := range []string{"260519/1", "260519/2", "260519/3"} {
		ids = append(ids, newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", sid).Id)
	}
	f := newTempusFake(t)
	r := newConditionsRunner(app, f, 2)

	res, err := r.Run(context.Background())
	if err != nil || res.Queried != 2 || res.Remaining != 1 {
		t.Fatalf("first run: %+v, %v", res, err)
	}
	final, empty := 0, 0
	for _, id := range ids {
		switch condStatus(t, app, id) {
		case conditions.StatusFinal:
			final++
		case "":
			empty++
		}
	}
	if final != 2 || empty != 1 {
		t.Errorf("after the first run: %d final, %d untouched; want 2 and 1", final, empty)
	}

	res, err = r.Run(context.Background())
	if err != nil || res.Queried != 1 || res.Remaining != 0 {
		t.Fatalf("second run: %+v, %v", res, err)
	}
	res, err = r.Run(context.Background())
	if err != nil || res.Queried != 0 || res.Remaining != 0 {
		t.Fatalf("third run: %+v, %v", res, err)
	}
	for _, id := range ids {
		if s := reload(t, app, "samples", id); s.GetFloat("weather_temperature_c") != 16 || len(conditions.Fields(s)) != 19 {
			t.Errorf("values not written: %v", s.GetFloat("weather_temperature_c"))
		}
	}
}

func TestConditionsRunner_SkipsProcessedAndCoordinateless(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	done := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	done.Set("conditions_status", conditions.StatusProvisional)
	done.Set("weather_temperature_c", 3.0)
	if err := app.SaveNoValidate(done); err != nil {
		t.Fatal(err)
	}
	noCoord := newSampleWithID(t, app, u.Id, 0, 0, "pending", "260519/2")
	f := newTempusFake(t)
	res, err := newConditionsRunner(app, f, 10).Run(context.Background())
	if err != nil || res.Queried != 0 || res.Remaining != 0 || f.hits.Load() != 0 {
		t.Fatalf("%+v, %v, hits %d", res, err, f.hits.Load())
	}
	if s := reload(t, app, "samples", done.Id); s.GetFloat("weather_temperature_c") != 3 {
		t.Error("a processed sample was touched")
	}
	if condStatus(t, app, noCoord.Id) != "" {
		t.Error("a sample without coordinate got a status")
	}
}

// Tempus is down: the sample is left pending for the hourly job and the
// run goes on with the next one.
func TestConditionsRunner_TempusDownLeavesPendingAndContinues(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	a := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	b := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/2")
	f := newTempusFake(t)
	f.fail.Store(true)
	res, err := newConditionsRunner(app, f, 10).Run(context.Background())
	if err != nil || res.Queried != 2 || res.Remaining != 0 {
		t.Fatalf("%+v, %v", res, err)
	}
	if condStatus(t, app, a.Id) != conditions.StatusPending || condStatus(t, app, b.Id) != conditions.StatusPending {
		t.Errorf("statuses: %q %q", condStatus(t, app, a.Id), condStatus(t, app, b.Id))
	}
}

// Cancelled mid-run: what is done stays done, the rest waits.
func TestConditionsRunner_CancelledContextStops(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	first := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	second := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/2")
	f := newTempusFake(t)
	ctx, cancel := context.WithCancel(context.Background())
	f.onHit = func(n int32) {
		if n == 1 {
			cancel()
		}
	}
	r := newConditionsRunner(app, f, 10)
	r.Interval = 50 * time.Millisecond
	res, err := r.Run(ctx)
	if err == nil {
		t.Fatal("a cancelled run must report the cancellation")
	}
	if res.Queried != 1 || res.Remaining != 1 {
		t.Errorf("%+v", res)
	}
	untouched := 0
	for _, id := range []string{first.Id, second.Id} {
		if condStatus(t, app, id) == "" {
			untouched++
		}
	}
	if untouched != 1 {
		t.Errorf("untouched samples = %d, want exactly the one not reached", untouched)
	}
}

// The app delivers values for a sample while the backfill runs over
// the others: when its turn comes it is no longer a legacy row.
func TestConditionsRunner_DoesNotOverwriteValuesDeliveredMeanwhile(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	a := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	b := newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/2")
	f := newTempusFake(t)
	var late string
	f.onHit = func(n int32) {
		if n != 1 {
			return
		}
		// Whichever sample is not being asked for right now.
		late = a.Id
		if condStatus(t, app, a.Id) == conditions.StatusPending {
			late = b.Id
		}
		rec := reload(t, app, "samples", late)
		rec.Set("conditions_status", conditions.StatusFinal)
		rec.Set("weather_temperature_c", 3.0)
		if err := app.SaveNoValidate(rec); err != nil {
			t.Error(err)
		}
	}
	res, err := newConditionsRunner(app, f, 10).Run(context.Background())
	if err != nil || res.Queried != 1 {
		t.Fatalf("%+v, %v", res, err)
	}
	if s := reload(t, app, "samples", late); s.GetFloat("weather_temperature_c") != 3 {
		t.Errorf("temperature = %v: the app's value was overwritten", s.GetFloat("weather_temperature_c"))
	}
}

func TestConditionsRunner_NilEnricherIsAnError(t *testing.T) {
	app := newApp(t)
	if _, err := (&ConditionsRunner{App: app}).Run(context.Background()); err == nil {
		t.Error("expected an error without a conditions enricher")
	}
	if _, err := (&ConditionsRunner{App: app, Conditions: &enrichment.ConditionsEnricher{App: app}}).Run(context.Background()); err == nil {
		t.Error("expected an error without a Tempus client")
	}
}

// Cancelled while the last (here: only) sample is being asked: the run
// must not report success.
func TestConditionsRunner_CancelDuringLastSampleIsReported(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	f := newTempusFake(t)
	ctx, cancel := context.WithCancel(context.Background())
	f.onHit = func(int32) { cancel() }
	if _, err := newConditionsRunner(app, f, 10).Run(ctx); err == nil {
		t.Fatal("cancellation during the last sample was reported as success")
	}
}

// The pause counts from the end of a sample: a slow query must not let
// the next one start right away.
func TestConditionsRunner_PausesAfterASlowSample(t *testing.T) {
	app := newApp(t)
	u := newUser(t, app)
	newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/1")
	newSampleWithID(t, app, u.Id, 48.1351, 11.582, "backend_service", "260519/2")
	f := newTempusFake(t)
	var firstDone, secondStart time.Time
	f.onHit = func(n int32) {
		if n == 1 {
			time.Sleep(300 * time.Millisecond) // slower than the interval
			firstDone = time.Now()
			return
		}
		secondStart = time.Now()
	}
	r := newConditionsRunner(app, f, 10)
	r.Interval = 200 * time.Millisecond
	if _, err := r.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if gap := secondStart.Sub(firstDone); gap < 180*time.Millisecond {
		t.Errorf("gap between the samples = %s, want at least the interval", gap)
	}
}
