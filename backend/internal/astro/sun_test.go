package astro

import (
	"math"
	"testing"
	"time"
)

// Test reference: Würzburg, 2026-05-10. According to timeanddate.com,
// sunrise is at 05:46 CEST (03:46 UTC) and sunset at 20:48 CEST
// (18:48 UTC). Civil twilight is roughly +/- 35 minutes around them.
// We tolerate +/- 5 minutes — well within the simplified algorithm's
// stated accuracy.
func TestComputeSunTimes_Wuerzburg_2026_05_10(t *testing.T) {
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Fatalf("tz: %v", err)
	}
	date := time.Date(2026, 5, 10, 12, 0, 0, 0, berlin)
	st := ComputeSunTimes(date, 49.7913, 9.9534)

	if st.Sunrise == nil {
		t.Fatal("sunrise nil")
	}
	if st.Sunset == nil {
		t.Fatal("sunset nil")
	}

	wantSunrise := time.Date(2026, 5, 10, 5, 46, 0, 0, berlin)
	wantSunset := time.Date(2026, 5, 10, 20, 48, 0, 0, berlin)

	if d := st.Sunrise.Sub(wantSunrise).Abs(); d > 5*time.Minute {
		t.Errorf("sunrise off by %v: got %v, want ~%v",
			d, st.Sunrise.In(berlin), wantSunrise)
	}
	if d := st.Sunset.Sub(wantSunset).Abs(); d > 5*time.Minute {
		t.Errorf("sunset off by %v: got %v, want ~%v",
			d, st.Sunset.In(berlin), wantSunset)
	}

	// Civil twilight should bracket sunrise/sunset.
	if st.CivilDawn == nil || st.CivilDusk == nil {
		t.Fatal("civil twilight nil for mid-latitude")
	}
	if !st.CivilDawn.Before(*st.Sunrise) {
		t.Errorf("CivilDawn %v should be before Sunrise %v", st.CivilDawn, st.Sunrise)
	}
	if !st.CivilDusk.After(*st.Sunset) {
		t.Errorf("CivilDusk %v should be after Sunset %v", st.CivilDusk, st.Sunset)
	}
}

func TestComputeSunTimes_PreservesLocation(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	date := time.Date(2026, 5, 10, 12, 0, 0, 0, berlin)
	st := ComputeSunTimes(date, 49.7913, 9.9534)
	if st.Sunrise.Location().String() != berlin.String() {
		t.Errorf("Sunrise location = %v, want %v", st.Sunrise.Location(), berlin)
	}
}

func TestComputeSunTimes_PolarDay(t *testing.T) {
	// June 21 at the North Pole: sun never sets.
	date := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	st := ComputeSunTimes(date, 89.9, 0)
	if st.Sunrise != nil || st.Sunset != nil {
		t.Errorf("expected nil sunrise/sunset at pole on summer solstice; got %v / %v",
			st.Sunrise, st.Sunset)
	}
}

func TestJulianDate_J2000(t *testing.T) {
	// J2000 epoch: 2000-01-01 12:00 UT = JD 2451545.0
	j2000 := time.Date(2000, 1, 1, 12, 0, 0, 0, time.UTC)
	got := julianDate(j2000)
	if math.Abs(got-2451545.0) > 1e-6 {
		t.Errorf("julianDate(J2000) = %v, want 2451545.0", got)
	}
}
