package hooks

import (
	"log/slog"
	"math"
	"time"

	"github.com/pocketbase/dbx"
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
	// Every save of a fieldtrip, also the ones the grouping does
	// itself: a flipped night flag moves the instant of its all-day
	// samples.
	app.OnRecordAfterUpdateSuccess("fieldtrips").BindFunc(func(e *core.RecordEvent) error {
		if e.Record.GetBool("night_fieldtrip") != e.Record.Original().GetBool("night_fieldtrip") {
			if err := resetAllDayConditions(e.App, e.Record.Id); err != nil {
				e.App.Logger().Warn("conditions: reset after night flag change failed",
					slog.String("fieldtrip_id", e.Record.Id), slog.Any("err", err))
			}
		}
		return e.Next()
	})
}

// resetAllDayConditions sets the all-day samples of a fieldtrip back to
// "pending" when their values were queried for another instant than
// the one that applies now (14:00 for a day, 22:00 for a night
// fieldtrip). The version is bumped so clients pick the change up; the
// refresh job asks Tempus again.
func resetAllDayConditions(app core.App, fieldtripID string) error {
	samples, err := app.FindRecordsByFilter("samples",
		"fieldtrip = {:ft} && is_all_day = true && (conditions_status = 'provisional' || conditions_status = 'final')",
		"", 0, 0, dbx.Params{"ft": fieldtripID})
	if err != nil {
		return err
	}
	for _, rec := range samples {
		want := SampleQueryInstant(app, rec)
		if conditions.SameInstant(rec.GetDateTime("conditions_queried_for").Time(), want) {
			continue
		}
		conditions.Clear(rec)
		rec.Set("version", rec.GetInt("version")+1)
		if err := app.SaveNoValidate(rec); err != nil {
			return err
		}
	}
	return nil
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
//     app asked Tempus itself): kept, with status and retry date
//     derived from the dates (conditions.CheckDelivered). After a move of coordinate or
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
	if delivered {
		delivered = normalizeDelivered(rec, want)
	}

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
		fetchedAnew := rec.GetDateTime("conditions_fetched_at").Time().
			After(orig.GetDateTime("conditions_fetched_at").Time())
		if !delivered || !fetchedAnew {
			conditions.Clear(rec)
		}
		return
	}
	if !delivered && conditions.Snapshot(rec) != conditions.Snapshot(orig) {
		conditions.Clear(rec)
	}
}

// nowFunc is the clock of this file (tests).
var nowFunc = time.Now

// normalizeDelivered replaces the status and retry date a client sent
// with the ones that follow from its dates. It reports false when the
// values are unusable (no or a future fetch date).
func normalizeDelivered(rec *core.Record, want time.Time) bool {
	status, retryAt, ok := conditions.CheckDelivered(
		rec.GetString("conditions_status"),
		want,
		rec.GetDateTime("conditions_fetched_at").Time(),
		rec.GetDateTime("conditions_retry_at").Time(),
		nowFunc(),
	)
	if !ok {
		return false
	}
	rec.Set("conditions_status", status)
	if retryAt.IsZero() {
		rec.Set("conditions_retry_at", "")
	} else {
		rec.Set("conditions_retry_at", retryAt.UTC())
	}
	return true
}
