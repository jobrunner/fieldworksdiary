// Package codes contains the pure logic for sample-code formation:
// computing the "collecting day" for a timestamp under a per-user
// rollover. Sample IDs are no longer formed by the backend. This
// package is intentionally dependency-free.
package codes

import "time"

// CollectingDay returns the calendar day (in t's location) that t
// counts as, given a per-user rollover hour. With cutoffHour=5, a
// timestamp at 03:00 belongs to the previous day; 05:00 starts the
// new day.
func CollectingDay(t time.Time, cutoffHour int) time.Time {
	shifted := t.Add(-time.Duration(cutoffHour) * time.Hour)
	y, m, d := shifted.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, shifted.Location())
}
