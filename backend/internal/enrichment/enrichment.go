// Package enrichment runs after a sample is inserted, calling the
// external services (labelloc, MTB) in a background goroutine and
// writing the trimmed results back to the sample. Failures here MUST
// NEVER affect the originating sample insert — that's already
// committed by the time we run.
package enrichment

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"runtime/debug"
	"time"

	"github.com/jbrunner/weevilapp/backend/internal/services"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
)

// Enricher knows how to fill admin_units / mtb on an already-saved
// sample. Construct one at startup, register the hook, then leave it.
type Enricher struct {
	App      *pocketbase.PocketBase
	Labelloc *services.Labelloc
	MTB      *services.MTB
	Logger   *slog.Logger
	// Timeout caps the entire enrichment work for one sample. Both
	// services run inside this budget.
	Timeout time.Duration
}

// Register wires the after-create hook on samples. The hook fires the
// enrichment in a goroutine so PocketBase's response is never blocked
// on the upstream services.
func (e *Enricher) Register() {
	e.App.OnRecordAfterCreateRequest("samples").Add(func(ev *core.RecordCreateEvent) error {
		recID := ev.Record.Id
		lat := ev.Record.GetFloat("lat")
		lon := ev.Record.GetFloat("lon")
		excID := ev.Record.GetString("excursion")
		go e.runSafely(recID, lat, lon, excID)
		return nil
	})
}

func (e *Enricher) runSafely(recordID string, lat, lon float64, excID string) {
	defer func() {
		if r := recover(); r != nil {
			e.log().Error("enrichment panic",
				slog.String("record_id", recordID),
				slog.Any("recover", r),
				slog.String("stack", string(debug.Stack())),
			)
		}
	}()

	timeout := e.Timeout
	if timeout == 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// 1. Sample enrichment (labelloc + MTB) — also propagates
	//    admin_units / mtb / locality-derived name onto the parent
	//    excursion if those slots are still empty.
	e.run(ctx, recordID, lat, lon)

	// 2. Excursion derived fields (centroid + astro). Runs after the
	//    sample enrichment so any name-promotion on the excursion is
	//    already committed by the time we re-save it here. The
	//    astro recomputation is purely local (no network), cheap.
	if excID != "" {
		e.recomputeExcursionDerived(excID)
	}
}

func (e *Enricher) run(ctx context.Context, recordID string, lat, lon float64) {
	dao := e.App.Dao()
	rec, err := dao.FindRecordById("samples", recordID)
	if err != nil {
		e.log().Warn("enrichment: sample disappeared", slog.String("id", recordID), slog.Any("err", err))
		return
	}

	type result struct {
		field string
		data  any
		err   error
	}
	results := make(chan result, 2)

	go func() {
		if e.Labelloc == nil {
			results <- result{field: "admin_units"}
			return
		}
		r, err := e.Labelloc.Lookup(ctx, lat, lon, "de")
		if err != nil {
			results <- result{field: "admin_units", err: err}
			return
		}
		results <- result{field: "admin_units", data: r}
	}()

	go func() {
		if e.MTB == nil {
			results <- result{field: "mtb"}
			return
		}
		r, err := e.MTB.Lookup(ctx, lat, lon)
		if err != nil {
			results <- result{field: "mtb", err: err}
			return
		}
		// Outside DE the service typically returns found=false; we
		// store the empty result so we don't keep retrying.
		results <- result{field: "mtb", data: r}
	}()

	dirty := false
	for i := 0; i < 2; i++ {
		r := <-results
		if r.err != nil {
			e.log().Warn("enrichment service failed",
				slog.String("field", r.field),
				slog.String("record_id", recordID),
				slog.Any("err", r.err),
			)
			continue
		}
		if r.data == nil {
			continue
		}
		raw, err := json.Marshal(r.data)
		if err != nil {
			e.log().Warn("enrichment marshal failed",
				slog.String("field", r.field),
				slog.Any("err", err),
			)
			continue
		}
		rec.Set(r.field, string(raw))
		dirty = true
	}

	if !dirty {
		return
	}

	if err := dao.SaveRecord(rec); err != nil {
		// One common reason this fails is PocketBase rejecting our
		// internal save when the record was meanwhile deleted; that's
		// fine, just log and move on.
		level := slog.LevelWarn
		if errors.Is(err, sql.ErrNoRows) {
			level = slog.LevelDebug
		}
		e.log().Log(ctx, level, "enrichment: save failed",
			slog.String("record_id", recordID),
			slog.Any("err", err),
		)
		return
	}

	// Lift admin_units / mtb up to the excursion if the excursion
	// doesn't already have them. Best-effort; not transactional with
	// the sample save.
	e.maybePropagateToExcursion(rec)
}

// maybePropagateToExcursion fills the excursion's admin_units and mtb
// fields from this sample if the excursion is still empty. We only
// promote — never overwrite — so manual edits stick.
func (e *Enricher) maybePropagateToExcursion(sample *models.Record) {
	excID := sample.GetString("excursion")
	if excID == "" {
		return
	}
	dao := e.App.Dao()
	exc, err := dao.FindRecordById("excursions", excID)
	if err != nil {
		return
	}
	dirty := false
	if au := sample.GetString("admin_units"); au != "" && exc.GetString("admin_units") == "" {
		exc.Set("admin_units", au)
		dirty = true
	}
	if mtb := sample.GetString("mtb"); mtb != "" && exc.GetString("mtb") == "" {
		exc.Set("mtb", mtb)
		dirty = true
	}
	// If the excursion still has its default name and we now know the
	// locality, upgrade the name. The default starts with "Sammeltag
	// ", so a strict prefix check is enough.
	if au := sample.GetString("admin_units"); au != "" {
		if locality := localityFromAdminUnits(au); locality != "" {
			currentName := exc.GetString("name")
			if currentName == "" || hasDefaultPrefix(currentName) {
				day := exc.GetString("collecting_day")
				if day != "" {
					exc.Set("name", locality+" — "+day)
				} else {
					exc.Set("name", locality)
				}
				dirty = true
			}
		}
	}
	if !dirty {
		return
	}
	if err := dao.SaveRecord(exc); err != nil {
		e.log().Warn("enrichment: excursion save failed",
			slog.String("id", excID),
			slog.Any("err", err),
		)
	}
}

func localityFromAdminUnits(raw string) string {
	var v struct {
		Locality string `json:"locality"`
	}
	if json.Unmarshal([]byte(raw), &v) != nil {
		return ""
	}
	return v.Locality
}

func hasDefaultPrefix(name string) bool {
	const prefix = "Sammeltag "
	return len(name) >= len(prefix) && name[:len(prefix)] == prefix
}

func (e *Enricher) log() *slog.Logger {
	if e.Logger != nil {
		return e.Logger
	}
	return e.App.Logger()
}
