package astro

import (
	"math"
	"time"
)

// MoonInfo collects everything the excursion view cares about.
type MoonInfo struct {
	// Phase is in [0, 1): 0 = new, 0.25 = first quarter, 0.5 = full,
	// 0.75 = last quarter.
	Phase float64 `json:"phase"`

	// PhaseName is a human-readable German label suitable for the UI.
	PhaseName string `json:"phase_name,omitempty"`

	// Illumination is the fraction of the visible disk that is lit,
	// in [0, 1].
	Illumination float64 `json:"illumination"`

	// Rise / Set on the calendar day of the input date, scanned at
	// 1-minute resolution. Either can be nil if the moon does not
	// cross the horizon on that day at that latitude.
	Rise *time.Time `json:"rise,omitempty"`
	Set  *time.Time `json:"set,omitempty"`
}

// Reference new moon: 2000-01-06 18:14 UT  (JD ≈ 2451550.26).
const (
	synodicMonth = 29.530588853
	refNewMoonJD = 2451550.26
)

// MoonPhase returns the synodic phase of the moon at time t, in
// [0, 1). The reference instant is the new moon on 2000-01-06 18:14
// UT; the synodic month is 29.530589 days.
func MoonPhase(t time.Time) float64 {
	jd := julianDate(t)
	p := math.Mod((jd-refNewMoonJD)/synodicMonth, 1)
	if p < 0 {
		p += 1
	}
	return p
}

// MoonIllumination returns the lit fraction of the moon's visible
// disk derived from the synodic phase. This is a simple model that
// ignores parallax; good to ~1 percentage point.
func MoonIllumination(phase float64) float64 {
	return (1 - math.Cos(2*math.Pi*phase)) / 2
}

// MoonPhaseName returns a German label for the phase.
func MoonPhaseName(phase float64) string {
	switch {
	case phase < 0.03 || phase >= 0.97:
		return "Neumond"
	case phase < 0.22:
		return "zunehmender Sichelmond"
	case phase < 0.28:
		return "erstes Viertel"
	case phase < 0.47:
		return "zunehmender Mond"
	case phase < 0.53:
		return "Vollmond"
	case phase < 0.72:
		return "abnehmender Mond"
	case phase < 0.78:
		return "letztes Viertel"
	default:
		return "abnehmender Sichelmond"
	}
}

// moonEquatorial returns the moon's right ascension and declination
// (degrees) at time t, using a simplified set of Meeus terms. Accuracy
// is ~0.5°, plenty for a "was the moon up?" check.
func moonEquatorial(t time.Time) (alpha, delta float64) {
	jd := julianDate(t)
	d := jd - 2451545.0

	Lp := mod360(218.316 + 13.176396*d) // mean longitude
	M := mod360(134.963 + 13.064993*d)  // mean anomaly
	F := mod360(93.272 + 13.229350*d)   // argument of latitude

	mRad := deg2rad(M)
	fRad := deg2rad(F)

	lambda := Lp + 6.289*math.Sin(mRad)
	beta := 5.128 * math.Sin(fRad)

	lambdaRad := deg2rad(lambda)
	betaRad := deg2rad(beta)
	epsRad := deg2rad(23.439 - 0.0000004*d)

	alphaRad := math.Atan2(
		math.Sin(lambdaRad)*math.Cos(epsRad)-math.Tan(betaRad)*math.Sin(epsRad),
		math.Cos(lambdaRad),
	)
	deltaRad := math.Asin(
		math.Sin(betaRad)*math.Cos(epsRad) + math.Cos(betaRad)*math.Sin(epsRad)*math.Sin(lambdaRad),
	)
	return mod360(rad2deg(alphaRad)), rad2deg(deltaRad)
}

// gmst returns the Greenwich Mean Sidereal Time at instant t, in
// degrees, using the IAU 1982 formula reduced to its leading terms.
func gmst(t time.Time) float64 {
	jd := julianDate(t)
	d := jd - 2451545.0
	g := 280.46061837 + 360.98564736629*d
	return mod360(g)
}

// MoonAltitude returns the moon's altitude at time t for an observer
// at (lat, lon), in degrees. Negative = below horizon.
func MoonAltitude(t time.Time, lat, lon float64) float64 {
	alpha, delta := moonEquatorial(t)
	lst := mod360(gmst(t) + lon)
	hRad := deg2rad(lst - alpha)

	latRad := deg2rad(lat)
	deltaRad := deg2rad(delta)

	sinAlt := math.Sin(latRad)*math.Sin(deltaRad) +
		math.Cos(latRad)*math.Cos(deltaRad)*math.Cos(hRad)
	return rad2deg(math.Asin(sinAlt))
}

// MoonAboveHorizonDuring reports whether the moon was above the
// horizon at any point in [start, end]. Resolution is 1 minute, which
// is well below typical excursion granularity.
func MoonAboveHorizonDuring(start, end time.Time, lat, lon float64) bool {
	if !end.After(start) {
		return MoonAltitude(start, lat, lon) > 0
	}
	step := time.Minute
	for t := start; !t.After(end); t = t.Add(step) {
		if MoonAltitude(t, lat, lon) > 0 {
			return true
		}
	}
	return false
}

// MaxMoonAltitudeDuring returns the maximum moon altitude (degrees)
// over [start, end], sampled every minute. Negative if the moon was
// always below the horizon (the most negative value in the window).
func MaxMoonAltitudeDuring(start, end time.Time, lat, lon float64) float64 {
	if !end.After(start) {
		return MoonAltitude(start, lat, lon)
	}
	step := time.Minute
	max := math.Inf(-1)
	for t := start; !t.After(end); t = t.Add(step) {
		a := MoonAltitude(t, lat, lon)
		if a > max {
			max = a
		}
	}
	return max
}

// ScanMoonRiseSet finds the moon's first rise and first set on the
// calendar day of `date` (in date's location), at the given coords.
// 1-minute resolution. Either return value can be nil if the
// corresponding crossing does not occur on that day.
func ScanMoonRiseSet(date time.Time, lat, lon float64) (rise, set *time.Time) {
	loc := date.Location()
	dayStart := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, loc)
	dayEnd := dayStart.Add(24 * time.Hour)
	step := time.Minute

	prev := MoonAltitude(dayStart, lat, lon)
	for t := dayStart.Add(step); !t.After(dayEnd); t = t.Add(step) {
		cur := MoonAltitude(t, lat, lon)
		if prev <= 0 && cur > 0 && rise == nil {
			r := t
			rise = &r
		}
		if prev >= 0 && cur < 0 && set == nil {
			s := t
			set = &s
		}
		if rise != nil && set != nil {
			break
		}
		prev = cur
	}
	return rise, set
}
