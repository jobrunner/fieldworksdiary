package conditions

import (
	"testing"
	"time"
)

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return v
}

func TestQueryInstant(t *testing.T) {
	cases := []struct {
		name   string
		begin  string
		zone   string
		allDay bool
		night  bool
		want   string
	}{
		{"timed sample keeps its begin", "2026-07-01T09:07:30Z", "Europe/Berlin", false, false, "2026-07-01T09:07:30Z"},
		{"all-day summer is 14:00 local", "2026-06-30T22:00:00Z", "Europe/Berlin", true, false, "2026-07-01T12:00:00Z"},
		{"all-day winter is 14:00 local", "2026-01-14T23:00:00Z", "Europe/Berlin", true, false, "2026-01-15T13:00:00Z"},
		{"all-day night trip is 22:00 local", "2026-06-30T22:00:00Z", "Europe/Berlin", true, true, "2026-07-01T20:00:00Z"},
		{"all-day on the DST switch day", "2026-03-28T23:00:00Z", "Europe/Berlin", true, false, "2026-03-29T12:00:00Z"},
		{"all-day far from UTC stays on the local day", "2026-11-16T11:00:00Z", "Pacific/Auckland", true, false, "2026-11-17T01:00:00Z"},
		{"unknown zone falls back to UTC", "2026-07-01T00:00:00Z", "Nicht/Da", true, false, "2026-07-01T14:00:00Z"},
		{"empty zone falls back to UTC", "2026-07-01T00:00:00Z", "", true, true, "2026-07-01T22:00:00Z"},
		{"night without all-day keeps the begin", "2026-07-01T09:07:30Z", "Europe/Berlin", false, true, "2026-07-01T09:07:30Z"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := QueryInstant(mustTime(t, c.begin), c.zone, c.allDay, c.night)
			if !got.Equal(mustTime(t, c.want)) {
				t.Errorf("got %s, want %s", got.Format(time.RFC3339), c.want)
			}
			if got.Location() != time.UTC {
				t.Errorf("location = %s, want UTC", got.Location())
			}
		})
	}
}

func TestQueryInstant_TruncatesToSeconds(t *testing.T) {
	begin := mustTime(t, "2026-07-01T09:07:30Z").Add(750 * time.Millisecond)
	got := QueryInstant(begin, "Europe/Berlin", false, false)
	if got.Nanosecond() != 0 || !got.Equal(mustTime(t, "2026-07-01T09:07:30Z")) {
		t.Errorf("got %s", got.Format(time.RFC3339Nano))
	}
}

func TestSameInstant(t *testing.T) {
	a := mustTime(t, "2026-07-01T09:07:30Z")
	if !SameInstant(a, a.Add(400*time.Millisecond)) {
		t.Error("sub-second difference must count as the same instant")
	}
	if SameInstant(a, a.Add(time.Second)) {
		t.Error("one second apart must differ")
	}
	if SameInstant(a, time.Time{}) {
		t.Error("zero time must not match")
	}
}

func TestIsFinalAge(t *testing.T) {
	instant := mustTime(t, "2026-07-01T12:00:00Z")
	if !IsFinalAge(instant, instant.Add(120*time.Hour)) {
		t.Error("exactly 120 h must be final")
	}
	if IsFinalAge(instant, instant.Add(119*time.Hour+59*time.Minute)) {
		t.Error("119 h 59 m must not be final")
	}
	if IsFinalAge(instant, instant.Add(-time.Hour)) {
		t.Error("an instant in the future must not be final")
	}
}
