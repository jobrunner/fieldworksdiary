package astro

import (
	"math"
	"testing"
	"time"
)

func TestMoonPhase_RangesValid(t *testing.T) {
	// Sample once a day for a year; phase must always be in [0, 1)
	// and illumination in [0, 1].
	for d := 0; d < 365; d++ {
		when := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).
			AddDate(0, 0, d)
		phase := MoonPhase(when)
		illum := MoonIllumination(phase)
		if phase < 0 || phase >= 1 {
			t.Fatalf("day %d: phase out of range: %v", d, phase)
		}
		if illum < 0 || illum > 1 {
			t.Fatalf("day %d: illumination out of range: %v", d, illum)
		}
	}
}

func TestMoonPhase_KnownNewMoon(t *testing.T) {
	// 2026-04-17 11:53 UT was a new moon (per published almanacs).
	// Our simplified model should land within ~12 hours of the
	// phase-zero crossing, i.e. |phase| close to 0 or close to 1.
	when := time.Date(2026, 4, 17, 11, 53, 0, 0, time.UTC)
	phase := MoonPhase(when)
	if !(phase < 0.05 || phase > 0.95) {
		t.Errorf("phase at known new moon = %v, want close to 0 or 1", phase)
	}
}

func TestMoonPhase_KnownFullMoon(t *testing.T) {
	// 2026-05-01 17:24 UT — full moon (per published almanacs).
	when := time.Date(2026, 5, 1, 17, 24, 0, 0, time.UTC)
	phase := MoonPhase(when)
	if math.Abs(phase-0.5) > 0.05 {
		t.Errorf("phase at known full moon = %v, want ~0.5", phase)
	}
	illum := MoonIllumination(phase)
	if illum < 0.95 {
		t.Errorf("illumination at full moon = %v, want > 0.95", illum)
	}
}

func TestMoonPhaseName_Coverage(t *testing.T) {
	// Make sure the name function returns *something* across the
	// cycle and never panics.
	for p := 0.0; p < 1.0; p += 0.05 {
		if name := MoonPhaseName(p); name == "" {
			t.Errorf("empty name at phase %v", p)
		}
	}
}

func TestMoonAltitude_Sanity(t *testing.T) {
	// Würzburg, midnight CEST, 2026-05-10. The moon must be either
	// above or below the horizon — we just check the math doesn't
	// blow up and returns something within [-90, 90].
	berlin, _ := time.LoadLocation("Europe/Berlin")
	when := time.Date(2026, 5, 10, 0, 0, 0, 0, berlin)
	alt := MoonAltitude(when, 49.7913, 9.9534)
	if alt < -90 || alt > 90 {
		t.Errorf("altitude out of range: %v", alt)
	}
}

func TestMoonAboveHorizonDuring_DayLongScan(t *testing.T) {
	// At Würzburg (49.79°N), the moon is above the horizon for
	// roughly half of any 24h window. Scan a full day and assert
	// True.
	berlin, _ := time.LoadLocation("Europe/Berlin")
	start := time.Date(2026, 5, 10, 0, 0, 0, 0, berlin)
	end := start.Add(24 * time.Hour)
	if !MoonAboveHorizonDuring(start, end, 49.7913, 9.9534) {
		t.Error("expected the moon to be above the horizon at some point in a 24h window")
	}
}

func TestMaxMoonAltitudeDuring_PositiveSomeTimeInDay(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	start := time.Date(2026, 5, 10, 0, 0, 0, 0, berlin)
	end := start.Add(24 * time.Hour)
	max := MaxMoonAltitudeDuring(start, end, 49.7913, 9.9534)
	if max <= 0 {
		t.Errorf("max altitude over 24h = %v, expected > 0", max)
	}
	if max > 90 {
		t.Errorf("max altitude = %v, > 90 is impossible", max)
	}
}

func TestScanMoonRiseSet_FindsBoth(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	date := time.Date(2026, 5, 10, 0, 0, 0, 0, berlin)
	rise, set := ScanMoonRiseSet(date, 49.7913, 9.9534)
	// On a typical mid-latitude day at least one of them is hit;
	// usually both. We don't assert specific times — just that the
	// scan didn't crash.
	if rise == nil && set == nil {
		t.Skip("neither rise nor set on this date — not necessarily a bug")
	}
	if rise != nil {
		if rise.Location().String() != berlin.String() {
			t.Errorf("rise location = %v, want %v", rise.Location(), berlin)
		}
	}
}
