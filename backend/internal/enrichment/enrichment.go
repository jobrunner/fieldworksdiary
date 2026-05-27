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

	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
)

// Enricher knows how to fill admin_units / mtb on an already-saved
// sample. Construct one at startup, register the hook, then leave it.
//
// `App` ist absichtlich auf `core.App` getypt (Interface), damit Tests
// `tests.TestApp` direkt einsetzen können — `*pocketbase.PocketBase`
// implementiert das Interface via eingebettetem `*core.BaseApp` ebenso.
type Enricher struct {
	App      core.App
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
		lat := ev.Record.GetFloat("latitude")
		lon := ev.Record.GetFloat("longitude")
		ftID := ev.Record.GetString("fieldtrip")
		go e.runSafely(recID, lat, lon, ftID)
		return nil
	})
}

func (e *Enricher) runSafely(recordID string, lat, lon float64, ftID string) {
	defer func() {
		if r := recover(); r != nil {
			e.log().Error(
				"enrichment panic",
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
	//    fieldtrip if those slots are still empty.
	e.run(ctx, recordID, lat, lon)

	// 2. Fieldtrip derived fields (centroid + astro). Runs after the
	//    sample enrichment so any name-promotion on the fieldtrip is
	//    already committed by the time we re-save it here. The
	//    astro recomputation is purely local (no network), cheap.
	if ftID != "" {
		e.recomputeFieldtripDerived(ftID)
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

	// admin_units no longer lives on the sample (R7.4). We keep the
	// labelloc snapshot in a local and push it straight to the
	// fieldtrip; only mtb is still a sample column.
	var adminUnits string
	dirty := false
	for i := 0; i < 2; i++ {
		r := <-results
		if r.err != nil {
			e.log().Warn(
				"enrichment service failed",
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
			e.log().Warn(
				"enrichment marshal failed",
				slog.String("field", r.field),
				slog.Any("err", err),
			)
			continue
		}
		switch r.field {
		case "admin_units":
			adminUnits = string(raw)
		default:
			rec.Set(r.field, string(raw))
			dirty = true
		}
	}

	if dirty {
		if err := dao.SaveRecord(rec); err != nil {
			// One common reason this fails is PocketBase rejecting our
			// internal save when the record was meanwhile deleted; that's
			// fine, just log and move on.
			level := slog.LevelWarn
			if errors.Is(err, sql.ErrNoRows) {
				level = slog.LevelDebug
			}
			e.log().Log(
				ctx, level, "enrichment: save failed",
				slog.String("record_id", recordID),
				slog.Any("err", err),
			)
			return
		}
	}

	// Lift admin_units / mtb up to the fieldtrip if the fieldtrip
	// doesn't already have them. Best-effort; not transactional with
	// the sample save.
	e.maybePropagateToFieldtrip(rec, adminUnits)
}

// maybePropagateToFieldtrip fills the fieldtrip's admin_units and mtb
// fields if the fieldtrip is still empty. We only promote — never
// overwrite — so manual edits stick. `adminUnits` is the labelloc
// snapshot for this sample, passed in by the caller because — since
// R7.4 — it is no longer persisted on the sample itself; mtb still is.
func (e *Enricher) maybePropagateToFieldtrip(sample *models.Record, adminUnits string) {
	ftID := sample.GetString("fieldtrip")
	if ftID == "" {
		return
	}
	dao := e.App.Dao()
	ft, err := dao.FindRecordById("fieldtrips", ftID)
	if err != nil {
		return
	}
	dirty := false
	if adminUnits != "" && ft.GetString("admin_units") == "" {
		ft.Set("admin_units", adminUnits)
		dirty = true
	}
	if mtb := sample.GetString("mtb"); mtb != "" && ft.GetString("mtb") == "" {
		ft.Set("mtb", mtb)
		dirty = true
	}
	// If the fieldtrip still has its default title and we now know the
	// locality, upgrade the title. The default starts with "Sammeltag
	// ", so a strict prefix check is enough.
	if adminUnits != "" {
		if locality := localityFromAdminUnits(adminUnits); locality != "" {
			currentTitle := ft.GetString("title")
			if currentTitle == "" || hasDefaultPrefix(currentTitle) {
				day := ft.GetString("collecting_day")
				if day != "" {
					ft.Set("title", locality+" — "+day)
				} else {
					ft.Set("title", locality)
				}
				dirty = true
			}
		}
	}
	if !dirty {
		return
	}
	if err := dao.SaveRecord(ft); err != nil {
		e.log().Warn(
			"enrichment: fieldtrip save failed",
			slog.String("id", ftID),
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
