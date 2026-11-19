// Package conditions holds the core logic for the weather, climate and
// astronomy values of a sample ("conditions"), which come from the
// Tempus service: the instant a sample is queried for, and the mapping
// of a Tempus answer onto sample fields, status and features. Pure
// functions without I/O; the service call lives in internal/services,
// the wiring in internal/enrichment.
package conditions

import "time"

// FinalAfter is how old the queried instant must be before Tempus
// answers from the final archive instead of forecast data.
const FinalAfter = 120 * time.Hour

// Local hours queried for a sample without a time of day.
const (
	allDayHour      = 14
	allDayNightHour = 22
)

// QueryInstant returns the instant (UTC, whole seconds) Tempus is asked
// for:
//
//   - a sample with a time of day: its begin
//   - an all-day sample: 14:00 on the local calendar day of begin in
//     zone
//   - an all-day sample of a night fieldtrip: 22:00 on that day
//
// An unknown or empty zone counts as UTC.
func QueryInstant(begin time.Time, zone string, allDay, night bool) time.Time {
	if !allDay {
		return begin.UTC().Truncate(time.Second)
	}
	loc, err := time.LoadLocation(zone)
	if err != nil || zone == "" {
		loc = time.UTC
	}
	hour := allDayHour
	if night {
		hour = allDayNightHour
	}
	y, m, d := begin.In(loc).Date()
	return time.Date(y, m, d, hour, 0, 0, 0, loc).UTC()
}

// SameInstant reports whether a and b are the same instant to the
// second (stored dates lose sub-second precision). A zero time never
// matches.
func SameInstant(a, b time.Time) bool {
	if a.IsZero() || b.IsZero() {
		return false
	}
	return a.UTC().Truncate(time.Second).Equal(b.UTC().Truncate(time.Second))
}

// IsFinalAge reports whether instant was at least FinalAfter in the
// past when the answer was fetched.
func IsFinalAge(instant, fetchedAt time.Time) bool {
	return fetchedAt.Sub(instant) >= FinalAfter
}
