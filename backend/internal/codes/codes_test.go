package codes

import (
	"testing"
	"time"
)

func TestCollectingDay(t *testing.T) {
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Fatalf("load timezone: %v", err)
	}

	cases := []struct {
		name       string
		input      time.Time
		cutoffHour int
		want       time.Time
	}{
		{
			name:       "noon belongs to that day",
			input:      time.Date(2026, 5, 9, 12, 0, 0, 0, berlin),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 9, 0, 0, 0, 0, berlin),
		},
		{
			name:       "early morning before cutoff belongs to previous day",
			input:      time.Date(2026, 5, 9, 3, 0, 0, 0, berlin),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 8, 0, 0, 0, 0, berlin),
		},
		{
			name:       "exactly at cutoff hour starts the new day",
			input:      time.Date(2026, 5, 9, 5, 0, 0, 0, berlin),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 9, 0, 0, 0, 0, berlin),
		},
		{
			name:       "one second before cutoff still previous day",
			input:      time.Date(2026, 5, 9, 4, 59, 59, 0, berlin),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 8, 0, 0, 0, 0, berlin),
		},
		{
			name:       "midnight with cutoff 5 belongs to previous day",
			input:      time.Date(2026, 5, 9, 0, 0, 0, 0, berlin),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 8, 0, 0, 0, 0, berlin),
		},
		{
			name:       "cutoff zero collapses to calendar day",
			input:      time.Date(2026, 5, 9, 23, 30, 0, 0, berlin),
			cutoffHour: 0,
			want:       time.Date(2026, 5, 9, 0, 0, 0, 0, berlin),
		},
		{
			name:       "preserves the input location",
			input:      time.Date(2026, 5, 9, 12, 0, 0, 0, time.UTC),
			cutoffHour: 5,
			want:       time.Date(2026, 5, 9, 0, 0, 0, 0, time.UTC),
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := CollectingDay(c.input, c.cutoffHour)
			if !got.Equal(c.want) {
				t.Errorf("CollectingDay(%v, %d) = %v, want %v",
					c.input, c.cutoffHour, got, c.want)
			}
			if got.Location() != c.input.Location() {
				t.Errorf("location lost: got %v, want %v",
					got.Location(), c.input.Location())
			}
		})
	}
}

func TestFormatCode(t *testing.T) {
	day := time.Date(2026, 5, 9, 0, 0, 0, 0, time.UTC)

	cases := []struct {
		seq  int
		want string
	}{
		{1, "260509/1"},
		{12, "260509/12"},
		{99, "260509/99"},
	}

	for _, c := range cases {
		if got := FormatCode(day, c.seq); got != c.want {
			t.Errorf("FormatCode(day, %d) = %q, want %q", c.seq, got, c.want)
		}
	}
}

func TestParseSequence(t *testing.T) {
	cases := []struct {
		code   string
		want   int
		ok     bool
	}{
		{"260510/1", 1, true},
		{"260510/12", 12, true},
		{"260510/99", 99, true},
		{"260510", 0, false},
		{"260510/", 0, false},
		{"260510/0", 0, false},
		{"260510/abc", 0, false},
		{"", 0, false},
		{"//", 0, false},
	}
	for _, c := range cases {
		got, ok := ParseSequence(c.code)
		if got != c.want || ok != c.ok {
			t.Errorf("ParseSequence(%q) = (%d, %v), want (%d, %v)",
				c.code, got, ok, c.want, c.ok)
		}
	}
}

func TestFormatCodeAcrossYearBoundary(t *testing.T) {
	day := time.Date(2025, 12, 31, 0, 0, 0, 0, time.UTC)
	got := FormatCode(day, 7)
	want := "251231/7"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	day = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	got = FormatCode(day, 1)
	want = "260101/1"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
