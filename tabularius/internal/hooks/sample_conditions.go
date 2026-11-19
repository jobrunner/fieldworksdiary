package hooks

import (
	"math"
	"time"

	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/tabularius/internal/conditions"
)

// RegisterSampleConditionsReset wires resetStaleConditions as create and
// update request hook on samples (before the save).
func RegisterSampleConditionsReset(app core.App) {
	app.OnRecordCreateRequest("samples").BindFunc(func(e *core.RecordRequestEvent) error {
		resetStaleConditions(e.App, e.Record, true)
		return e.Next()
	})
	app.OnRecordUpdateRequest("samples").BindFunc(func(e *core.RecordRequestEvent) error {
		resetStaleConditions(e.App, e.Record, false)
		return e.Next()
	})
}

// SampleQueryInstant returns the instant Tempus is asked for this
// sample: its begin, or 14:00 / 22:00 local for an all-day sample
// (22:00 when its fieldtrip is a night fieldtrip). A sample without a
// fieldtrip counts as a day sample.
func SampleQueryInstant(app core.App, rec *core.Record) time.Time {
	night := false
	if id := rec.GetString("fieldtrip"); id != "" {
		if ft, err := app.FindRecordById("fieldtrips", id); err == nil {
			night = ft.GetBool("night_fieldtrip")
		}
	}
	return conditions.QueryInstant(
		rec.GetDateTime("begin_date").Time(),
		rec.GetString("timezone"),
		rec.GetBool("is_all_day"),
		night,
	)
}

// resetStaleConditions decides, before a sample is saved, whether the
// weather/climate values on the record belong to its coordinate and
// time:
//
//   - no coordinate: no values, empty status
//   - the request carries values queried for the sample's instant (the
//     app asked Tempus itself): kept. After a move of coordinate or
//     instant that only holds for values fetched anew, not for the old
//     ones echoed back.
//   - coordinate or instant moved otherwise, or the request carries
//     values for another instant: cleared, status "pending" — the
//     enrichment takes over.
//   - anything else (e.g. only the notes changed) stays as it is; a row
//     from before Phase T keeps its empty status and is left to the
//     backfill.
func resetStaleConditions(app core.App, rec *core.Record, isCreate bool) {
	if rec.GetFloat("latitude") == 0 && rec.GetFloat("longitude") == 0 {
		conditions.Clear(rec)
		rec.Set("conditions_status", "")
		return
	}
	want := SampleQueryInstant(app, rec)
	status := rec.GetString("conditions_status")
	delivered := (status == conditions.StatusProvisional || status == conditions.StatusFinal) &&
		conditions.SameInstant(rec.GetDateTime("conditions_queried_for").Time(), want)

	if isCreate {
		if !delivered {
			conditions.Clear(rec)
		}
		return
	}

	orig := rec.Original()
	moved := math.Abs(rec.GetFloat("latitude")-orig.GetFloat("latitude")) > coordEpsilon ||
		math.Abs(rec.GetFloat("longitude")-orig.GetFloat("longitude")) > coordEpsilon ||
		!want.Equal(SampleQueryInstant(app, orig))
	if moved {
		fetchedAnew := !rec.GetDateTime("conditions_fetched_at").Time().
			Equal(orig.GetDateTime("conditions_fetched_at").Time())
		if !delivered || !fetchedAnew {
			conditions.Clear(rec)
		}
		return
	}
	if !delivered && conditions.Snapshot(rec) != conditions.Snapshot(orig) {
		conditions.Clear(rec)
	}
}
