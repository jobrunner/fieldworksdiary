package backfill

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/tabularius/internal/enrichment"
)

// Defaults of the conditions backfill. Every sample costs Tempus (and
// the weather source behind it) a full query, the climate normals being
// the expensive part; a run is therefore small and slow on purpose and
// meant to be repeated.
const (
	defaultConditionsLimit    = 200
	defaultConditionsInterval = 2 * time.Second
)

// legacyConditionsFilter selects the samples from before Phase T: a
// coordinate, but never processed.
const legacyConditionsFilter = "(latitude != 0 || longitude != 0) && conditions_status = ''"

// ErrNoConditionsEnricher is returned when the runner has no Tempus
// client to work with.
var ErrNoConditionsEnricher = errors.New("conditions backfill: no tempus client")

// ConditionsRunner fills weather, climate and astronomy for samples
// that existed before Phase T (empty conditions_status), oldest first.
// A run handles at most Limit samples; processed samples have a status
// afterwards, so the next run continues with the rest.
type ConditionsRunner struct {
	App core.App
	// Conditions does the per-sample work.
	Conditions *enrichment.ConditionsEnricher
	// Limit caps the samples of one run; zero means 200.
	Limit int
	// Interval is the pause between two samples; zero means 2 s.
	Interval time.Duration
	Logger   *slog.Logger
}

// ConditionsResult reports one run.
type ConditionsResult struct {
	// Queried counts the samples Tempus was asked for (also the ones
	// that failed and stay pending for the hourly refresh job).
	Queried int
	// Remaining counts the samples still waiting for a later run.
	Remaining int
}

func (r *ConditionsRunner) log() *slog.Logger {
	if r.Logger != nil {
		return r.Logger
	}
	return slog.Default()
}

// Run executes one backfill run. A cancelled context ends it with the
// context's error; what was done until then stays done.
func (r *ConditionsRunner) Run(ctx context.Context) (ConditionsResult, error) {
	var res ConditionsResult
	if r.Conditions == nil || r.Conditions.Tempus == nil {
		return res, ErrNoConditionsEnricher
	}
	limit, interval := r.Limit, r.Interval
	if limit <= 0 {
		limit = defaultConditionsLimit
	}
	if interval <= 0 {
		interval = defaultConditionsInterval
	}
	recs, err := r.App.FindRecordsByFilter("samples", legacyConditionsFilter, "created", limit, 0)
	if err != nil {
		return res, err
	}
	r.log().Info("conditions backfill: start", slog.String("service", "tempus"), slog.Int("count", len(recs)))

	var runErr error
	for i, rec := range recs {
		// The pause counts from the end of the previous sample, however
		// long its query took.
		if i > 0 {
			pause := time.NewTimer(interval)
			select {
			case <-ctx.Done():
				pause.Stop()
			case <-pause.C:
			}
		}
		if runErr = ctx.Err(); runErr != nil {
			break
		}
		if r.Conditions.BackfillSample(ctx, rec.Id) {
			res.Queried++
		}
	}
	// A cancellation during the last sample ends its query quietly;
	// report it all the same.
	if runErr == nil {
		runErr = ctx.Err()
	}

	remaining, err := r.App.CountRecords("samples", legacyConditionsExpr())
	if err != nil {
		return res, errors.Join(runErr, err)
	}
	res.Remaining = int(remaining)
	r.log().Info("conditions backfill: done", slog.String("service", "tempus"),
		slog.Int("queried", res.Queried), slog.Int("remaining", res.Remaining))
	return res, runErr
}

// legacyConditionsExpr is legacyConditionsFilter as an SQL expression
// for counting.
func legacyConditionsExpr() dbx.Expression {
	return dbx.NewExp("(latitude != 0 OR longitude != 0) AND conditions_status = ''")
}
