// Package codes contains the pure logic for sample-code formation:
// computing the "collecting day" for a timestamp under a per-user
// rollover, and formatting codes as YYMMDD/N.
//
// Sequence allocation (the N) is NOT here — it needs the database and
// lives next to the hooks. This package is intentionally dependency-free
// so both backend and (later) the iOS-mirror can share the rules.
package codes

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// CollectingDay returns the calendar day (in t's location) that t
// counts as, given a per-user rollover hour. With cutoffHour=5, a
// timestamp at 03:00 belongs to the previous day; 05:00 starts the
// new day.
func CollectingDay(t time.Time, cutoffHour int) time.Time {
	shifted := t.Add(-time.Duration(cutoffHour) * time.Hour)
	y, m, d := shifted.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, shifted.Location())
}

// FormatCode returns the canonical sample code "YYMMDD/N".
func FormatCode(day time.Time, seq int) string {
	return fmt.Sprintf("%s/%d", day.Format("060102"), seq)
}

// ParseSequence pulls the trailing N out of a "YYMMDD/N" code. Used
// on the server side to advance sample_sequences.last_seq when we
// honor a client-supplied code that doesn't conflict.
func ParseSequence(code string) (int, bool) {
	parts := strings.SplitN(code, "/", 2)
	if len(parts) != 2 {
		return 0, false
	}
	n, err := strconv.Atoi(parts[1])
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}
