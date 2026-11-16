package astro

import "time"

// FieldtripAstro is the JSON shape we persist on `fieldtrip.astro`.
// Field names match the §6.5 schema in PROJECT_PLAN.md.
type FieldtripAstro struct {
	Sunrise       *time.Time `json:"sunrise,omitempty"`
	Sunset        *time.Time `json:"sunset,omitempty"`
	CivilDawn     *time.Time `json:"civil_dawn,omitempty"`
	CivilDusk     *time.Time `json:"civil_dusk,omitempty"`
	MoonPhase     float64    `json:"moon_phase"`
	MoonPhaseName string     `json:"moon_phase_name,omitempty"`
	MoonIllum     float64    `json:"moon_illumination"`
	MoonRise      *time.Time `json:"moon_rise,omitempty"`
	MoonSet       *time.Time `json:"moon_set,omitempty"`
	MoonAbove     bool       `json:"moon_above_horizon_during_fieldtrip"`
	MoonAltMaxDeg float64    `json:"moon_altitude_max_during_deg"`
}

// ComputeFieldtripAstro combines all the per-fieldtrip derived
// quantities. `day` is the local calendar day of the fieldtrip
// (typically `fieldtrip.collecting_day` parsed in user's TZ);
// `start`/`end` are the fieldtrip's started_at/ended_at; (lat, lon)
// is the centroid.
func ComputeFieldtripAstro(day, start, end time.Time, lat, lon float64) FieldtripAstro {
	out := FieldtripAstro{}

	suns := ComputeSunTimes(day, lat, lon)
	out.Sunrise = suns.Sunrise
	out.Sunset = suns.Sunset
	out.CivilDawn = suns.CivilDawn
	out.CivilDusk = suns.CivilDusk

	// Moon phase / illumination — sample at solar noon of the day,
	// since the synodic phase changes only ~12°/day so any time on
	// the day is fine for display.
	noon := time.Date(day.Year(), day.Month(), day.Day(), 12, 0, 0, 0, day.Location())
	phase := MoonPhase(noon)
	out.MoonPhase = phase
	out.MoonPhaseName = MoonPhaseName(phase)
	out.MoonIllum = MoonIllumination(phase)

	rise, set := ScanMoonRiseSet(day, lat, lon)
	out.MoonRise = rise
	out.MoonSet = set

	if !start.IsZero() && !end.IsZero() {
		out.MoonAbove = MoonAboveHorizonDuring(start, end, lat, lon)
		out.MoonAltMaxDeg = roundTo(MaxMoonAltitudeDuring(start, end, lat, lon), 1)
	}

	return out
}

// roundTo rounds f to `digits` decimal places.
func roundTo(f float64, digits int) float64 {
	mult := 1.0
	for i := 0; i < digits; i++ {
		mult *= 10
	}
	return float64(int64(f*mult+sign(f)*0.5)) / mult
}

func sign(f float64) float64 {
	if f < 0 {
		return -1
	}
	return 1
}
