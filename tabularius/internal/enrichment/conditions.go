package enrichment

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"runtime/debug"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/tabularius/internal/conditions"
	"go.mett.io/tabularius/internal/geoplace"
	"go.mett.io/tabularius/internal/hooks"
	"go.mett.io/tabularius/internal/services"
)

const (
	tempusServiceName = "tempus"
	// pendingGrace keeps the refresh job away from a pending sample
	// whose create/update hook is probably still asking Tempus.
	pendingGrace = time.Hour
	// refreshCron runs the refresh job once an hour.
	refreshCron   = "7 * * * *"
	refreshCronID = "tempus-conditions"
	// refreshTimeout caps one run of the refresh job.
	refreshTimeout = 10 * time.Minute
	// pbDateLayout is PocketBase's datetime format in filters.
	pbDateLayout = "2006-01-02 15:04:05.000Z"
)

// ConditionsEnricher fills the weather, climate and astronomy values of
// a sample from Tempus: right after a create or update that left the
// sample "pending" (see hooks.RegisterSampleConditionsReset), and from
// an hourly job for samples whose values are still provisional. Like
// the Ortus enrichment it never affects the originating save.
type ConditionsEnricher struct {
	App core.App
	// Tempus is the service. Nil disables the enrichment.
	Tempus *services.Tempus
	Logger *slog.Logger
	// Timeout caps the work for one sample.
	Timeout time.Duration
	// Now is the clock (tests); nil means time.Now.
	Now func() time.Time

	// afterQuery runs between the Tempus call and the write (tests).
	afterQuery func()

	// inFlight serializes the runs for one sample: the create hook, the
	// Ortus run and the job may all trigger the same one. The second
	// run finds the sample already filled and does not ask again.
	inFlight sync.Map // sample id -> *sync.Mutex
	// slots caps the concurrent Tempus queries (a bulk sync creates
	// many samples at once; Tempus has a daily budget).
	slotsOnce sync.Once
	slots     chan struct{}
}

// maxConcurrentQueries is the cap on parallel Tempus queries.
const maxConcurrentQueries = 4

// lockSample serializes the work for one sample; call the returned
// function to release.
func (e *ConditionsEnricher) lockSample(sampleID string) func() {
	m, _ := e.inFlight.LoadOrStore(sampleID, &sync.Mutex{})
	mu, _ := m.(*sync.Mutex)
	mu.Lock()
	// The entry stays in the map: removing it while another run waits
	// on the mutex would let a third one start with a fresh mutex.
	return mu.Unlock
}

// acquireSlot waits for a free query slot or the end of ctx.
func (e *ConditionsEnricher) acquireSlot(ctx context.Context) (func(), bool) {
	e.slotsOnce.Do(func() { e.slots = make(chan struct{}, maxConcurrentQueries) })
	select {
	case e.slots <- struct{}{}:
		return func() { <-e.slots }, true
	case <-ctx.Done():
		return nil, false
	}
}

// Register wires the create and update hooks on samples. They run after
// the save and start the enrichment in a goroutine when the sample is
// pending.
func (e *ConditionsEnricher) Register() {
	trigger := func(ev *core.RecordRequestEvent) error {
		if err := ev.Next(); err != nil {
			return err
		}
		switch {
		case !hasCoordinate(ev.Record):
			go func(id string) {
				defer e.recoverPanic(id)
				e.dropFeaturesWithoutCoordinate(id)
			}(ev.Record.Id)
		case ev.Record.GetString("conditions_status") == conditions.StatusPending:
			go e.runSafely(ev.Record.Id)
		}
		return nil
	}
	e.App.OnRecordCreateRequest("samples").BindFunc(trigger)
	e.App.OnRecordUpdateRequest("samples").BindFunc(trigger)
}

// RegisterCron schedules the hourly refresh job; limit caps the Tempus
// queries of one run.
func (e *ConditionsEnricher) RegisterCron(limit int) {
	e.App.Cron().MustAdd(refreshCronID, refreshCron, func() {
		defer e.recoverPanic("")
		ctx, cancel := context.WithTimeout(context.Background(), refreshTimeout)
		defer cancel()
		n := e.RefreshDue(ctx, limit)
		e.log().Info("conditions: refresh run", slog.String("service", tempusServiceName), slog.Int("queried", n))
	})
}

func hasCoordinate(rec *core.Record) bool {
	return rec.GetFloat("latitude") != 0 || rec.GetFloat("longitude") != 0
}

func (e *ConditionsEnricher) recoverPanic(sampleID string) {
	if r := recover(); r != nil {
		e.log().Error(
			"conditions: panic",
			slog.String("sample_id", sampleID),
			slog.Any("recover", r),
			slog.String("stack", string(debug.Stack())),
		)
	}
}

func (e *ConditionsEnricher) runSafely(sampleID string) {
	defer e.recoverPanic(sampleID)
	timeout := e.Timeout
	if timeout == 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	e.EnrichSample(ctx, sampleID)
}

// RefreshDue asks Tempus again for the samples that are due and returns
// how many it queried (at most limit):
//
//   - provisional samples whose conditions_retry_at has passed (the
//     data was not available yet, or forecast data can now be replaced
//     by the archive). The new answer overwrites the values, also ones
//     the app delivered.
//   - pending samples with a coordinate that have been waiting longer
//     than pendingGrace (Tempus was unreachable when they were saved).
//
// Samples with an empty status (rows from before Phase T) are never
// picked: they are left to the backfill.
func (e *ConditionsEnricher) RefreshDue(ctx context.Context, limit int) int {
	if e.Tempus == nil || limit <= 0 {
		return 0
	}
	now := e.now().UTC()
	due, err := e.App.FindRecordsByFilter("samples",
		"conditions_status = 'provisional' && conditions_retry_at != '' && conditions_retry_at <= {:now}",
		"conditions_retry_at", limit, 0, dbx.Params{"now": now.Format(pbDateLayout)})
	if err != nil {
		e.log().Warn("conditions: refresh query failed", slog.String("service", tempusServiceName), slog.Any("err", err))
		return 0
	}
	if rest := limit - len(due); rest > 0 {
		pending, err := e.App.FindRecordsByFilter("samples",
			"conditions_status = 'pending' && (latitude != 0 || longitude != 0) && updated <= {:stale}",
			"updated", rest, 0, dbx.Params{"stale": now.Add(-pendingGrace).Format(pbDateLayout)})
		if err != nil {
			e.log().Warn("conditions: refresh query failed", slog.String("service", tempusServiceName), slog.Any("err", err))
		} else {
			due = append(due, pending...)
		}
	}
	queried := 0
	for _, rec := range due {
		if ctx.Err() != nil {
			break
		}
		e.refreshSafely(ctx, rec.Id)
		queried++
	}
	return queried
}

// refreshSafely runs refreshSample inside the caller's context with
// the per-sample timeout and panic recovery.
func (e *ConditionsEnricher) refreshSafely(ctx context.Context, sampleID string) {
	defer e.recoverPanic(sampleID)
	timeout := e.Timeout
	if timeout == 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	e.refreshSample(ctx, sampleID)
}

// EnrichSample asks Tempus for one pending sample and writes the answer
// (synchronously; the hooks call it through runSafely, the Ortus run
// directly). A provisional sample is left alone: its values may have
// come from the app, and asking again is the refresh job's business
// once its retry date has passed.
func (e *ConditionsEnricher) EnrichSample(ctx context.Context, sampleID string) {
	e.enrich(ctx, sampleID, false)
}

// refreshSample is EnrichSample for the refresh job: it also asks again
// for a provisional sample.
func (e *ConditionsEnricher) refreshSample(ctx context.Context, sampleID string) {
	e.enrich(ctx, sampleID, true)
}

// enrich does the work of EnrichSample and refreshSample. Failures are
// logged, never returned:
//
//   - no coordinate, another status, no Tempus: nothing to do
//
//   - Tempus error: the sample stays as it is; a pending sample loses
//     its Tempus features, which belonged to its former place or time
//
//   - coordinate or instant changed while Tempus was asked: skipped,
//     the update hook has queued its own run
//
//   - the conditions changed while Tempus was asked (the app delivered
//     its own, or another run was faster): skipped, theirs are newer
//
// The version is bumped only when values or features changed, so a
// re-query with the same answer sends no client into a 409.
func (e *ConditionsEnricher) enrich(ctx context.Context, sampleID string, provisionalToo bool) {
	if e.Tempus == nil {
		return
	}
	defer e.lockSample(sampleID)()
	log := e.log().With(slog.String("sample_id", sampleID))
	app := e.App
	rec, err := app.FindRecordById("samples", sampleID)
	if err != nil {
		log.Warn("conditions: sample disappeared", slog.Any("err", err))
		return
	}
	status := rec.GetString("conditions_status")
	if !hasCoordinate(rec) || !refreshable(status, provisionalToo) {
		return
	}
	seen := conditions.Snapshot(rec)
	seenFetched := rec.GetDateTime("conditions_fetched_at").Time()
	lat, lon := rec.GetFloat("latitude"), rec.GetFloat("longitude")
	want := hooks.SampleQueryInstant(app, rec)

	release, ok := e.acquireSlot(ctx)
	if !ok {
		log.Warn("conditions: no free query slot, sample stays as it is", slog.String("service", tempusServiceName))
		return
	}
	resp, err := e.Tempus.Query(ctx, lat, lon, want)
	release()
	if e.afterQuery != nil {
		e.afterQuery()
	}
	if err != nil {
		log.Warn("conditions: tempus query failed", slog.String("service", tempusServiceName), slog.Any("err", err))
		if status == conditions.StatusPending {
			e.dropStaleFeatures(sampleID, lat, lon, want, log)
		}
		return
	}
	res := conditions.FromTempus(resp, want, e.now())

	// Re-read, mutate and save in one transaction (no network inside),
	// so a client request landing in between is not clobbered.
	var bumped bool
	err = app.RunInTransaction(func(tx core.App) error {
		rec, err := tx.FindRecordById("samples", sampleID)
		if err != nil {
			return fmt.Errorf("sample disappeared: %w", err)
		}
		if math.Abs(rec.GetFloat("latitude")-lat) > coordEpsilon ||
			math.Abs(rec.GetFloat("longitude")-lon) > coordEpsilon ||
			!hooks.SampleQueryInstant(tx, rec).Equal(want) ||
			conditions.Snapshot(rec) != seen ||
			!rec.GetDateTime("conditions_fetched_at").Time().Equal(seenFetched) {
			return errSkip
		}
		before := seen
		retryBefore := rec.GetDateTime("conditions_retry_at").Time()
		conditions.Apply(rec, res)
		changed := conditions.Snapshot(rec) != before ||
			geoplace.FeaturesChanged(tx, sampleID, geoplace.ScopeTempus, res.Features)
		if !changed {
			if retryBefore.Equal(rec.GetDateTime("conditions_retry_at").Time()) {
				return nil
			}
			// Only the bookkeeping moved: no version bump.
			return tx.SaveNoValidate(rec)
		}
		// Bump the optimistic-concurrency counter like the version
		// guard does for client writes (see Enricher.run).
		rec.Set("version", rec.GetInt("version")+1)
		bumped = true
		if err := tx.SaveNoValidate(rec); err != nil {
			return fmt.Errorf("save sample: %w", err)
		}
		if err := geoplace.ReplaceFeatures(tx, sampleID, rec.GetString("owner"), geoplace.ScopeTempus, res.Features); err != nil {
			return fmt.Errorf("replace features: %w", err)
		}
		return nil
	})
	switch {
	case errors.Is(err, errSkip):
		log.Debug("conditions: sample changed during query, skipping")
		return
	case err != nil:
		log.Warn("conditions: write failed", slog.Any("err", err))
		return
	}
	log.Info(
		"conditions: sample enriched",
		slog.String("service", tempusServiceName),
		slog.String("conditions_status", res.Status),
		slog.Int("features", len(res.Features)),
		slog.Bool("changed", bumped),
	)
}

// refreshable reports whether a sample in this status is asked: a
// pending one always, a provisional one only by the refresh job.
func refreshable(status string, provisionalToo bool) bool {
	return status == conditions.StatusPending || (provisionalToo && status == conditions.StatusProvisional)
}

// dropStaleFeatures removes the Tempus features of a sample that is
// still pending for the same place and instant: they belonged to its
// former coordinate or time. The sample is re-read in the transaction,
// so features a client delivered while Tempus was failing are kept.
func (e *ConditionsEnricher) dropStaleFeatures(sampleID string, lat, lon float64, want time.Time, log *slog.Logger) {
	err := e.App.RunInTransaction(func(tx core.App) error {
		rec, err := tx.FindRecordById("samples", sampleID)
		if err != nil {
			return err
		}
		if rec.GetString("conditions_status") != conditions.StatusPending ||
			math.Abs(rec.GetFloat("latitude")-lat) > coordEpsilon ||
			math.Abs(rec.GetFloat("longitude")-lon) > coordEpsilon ||
			!hooks.SampleQueryInstant(tx, rec).Equal(want) ||
			!geoplace.FeaturesChanged(tx, sampleID, geoplace.ScopeTempus, nil) {
			return nil
		}
		return geoplace.ReplaceFeatures(tx, sampleID, rec.GetString("owner"), geoplace.ScopeTempus, nil)
	})
	if err != nil {
		log.Warn("conditions: dropping stale features failed", slog.String("service", tempusServiceName), slog.Any("err", err))
	}
}

// dropFeaturesWithoutCoordinate removes the Tempus features of a sample
// that has no coordinate (any more): they describe a place the sample
// is no longer at, and nothing else would ever replace them.
func (e *ConditionsEnricher) dropFeaturesWithoutCoordinate(sampleID string) {
	log := e.log().With(slog.String("sample_id", sampleID))
	err := e.App.RunInTransaction(func(tx core.App) error {
		rec, err := tx.FindRecordById("samples", sampleID)
		if err != nil {
			return err
		}
		if hasCoordinate(rec) || !geoplace.FeaturesChanged(tx, sampleID, geoplace.ScopeTempus, nil) {
			return nil
		}
		return geoplace.ReplaceFeatures(tx, sampleID, rec.GetString("owner"), geoplace.ScopeTempus, nil)
	})
	if err != nil {
		log.Warn("conditions: dropping features without coordinate failed",
			slog.String("service", tempusServiceName), slog.Any("err", err))
	}
}

func (e *ConditionsEnricher) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

func (e *ConditionsEnricher) log() *slog.Logger {
	if e.Logger != nil {
		return e.Logger
	}
	return e.App.Logger()
}
