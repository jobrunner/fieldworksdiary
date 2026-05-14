// Package astro contains the pure astronomical math we need for
// excursion enrichment: sun rise/set, civil twilight, moon phase /
// illumination / altitude, and the derived "was the moon above the
// horizon at any point during this window?" check.
//
// All input/output times are time.Time. The algorithms operate in UT
// internally; the caller's location is preserved on returned values.
//
// Accuracy targets:
//   - sunrise/sunset within ~1 minute at mid-latitudes
//   - moon phase / illumination within ~0.01 of the true value
//   - moon altitude within ~0.5 degrees
//
// References:
//   - NOAA solar position calculator
//   - Jean Meeus, "Astronomical Algorithms" (1998), simplified moon
package astro

import (
	"math"
	"time"
)

// SunTimes are the four daily transitions we expose. Any of them can
// be nil if the sun does not cross the corresponding altitude on the
// given date at the given latitude (polar day / polar night).
type SunTimes struct {
	CivilDawn *time.Time `json:"civil_dawn,omitempty"`
	Sunrise   *time.Time `json:"sunrise,omitempty"`
	Sunset    *time.Time `json:"sunset,omitempty"`
	CivilDusk *time.Time `json:"civil_dusk,omitempty"`
}

// ComputeSunTimes returns sunrise, sunset, civil dawn and civil dusk
// for the calendar day of `date` at the given coordinates. The
// returned times are in `date`'s location.
func ComputeSunTimes(date time.Time, lat, lon float64) SunTimes {
	loc := date.Location()
	noonUTC := time.Date(date.Year(), date.Month(), date.Day(), 12, 0, 0, 0, time.UTC)
	jd := julianDate(noonUTC)
	n := jd - 2451545.0

	// Solar mean longitude and anomaly (degrees).
	L := mod360(280.460 + 0.9856474*n)
	g := mod360(357.528 + 0.9856003*n)
	gRad := deg2rad(g)

	// Apparent ecliptic longitude.
	lambda := mod360(L + 1.915*math.Sin(gRad) + 0.020*math.Sin(2*gRad))
	lambdaRad := deg2rad(lambda)

	// Obliquity of the ecliptic.
	eps := 23.439 - 0.0000004*n
	epsRad := deg2rad(eps)

	// Right ascension and declination.
	alphaRad := math.Atan2(math.Cos(epsRad)*math.Sin(lambdaRad), math.Cos(lambdaRad))
	alpha := mod360(rad2deg(alphaRad))
	deltaRad := math.Asin(math.Sin(epsRad) * math.Sin(lambdaRad))

	// Equation of time, minutes.
	eot := 4 * (L - 0.0057183 - alpha)
	eot = wrap180(eot) // keep in (-180, 180]; EOT is < 20 minutes

	// Solar noon, minutes from UT midnight.
	solarNoonMin := 720 - 4*lon - eot

	latRad := deg2rad(lat)

	resolveAt := func(zenithDeg float64, offsetSign float64) *time.Time {
		zRad := deg2rad(zenithDeg)
		cosH := (math.Cos(zRad) - math.Sin(latRad)*math.Sin(deltaRad)) /
			(math.Cos(latRad) * math.Cos(deltaRad))
		if cosH < -1 || cosH > 1 {
			return nil
		}
		hDeg := rad2deg(math.Acos(cosH))
		minutesFromMidnight := solarNoonMin + offsetSign*4*hDeg
		t := time.Date(noonUTC.Year(), noonUTC.Month(), noonUTC.Day(), 0, 0, 0, 0, time.UTC).
			Add(time.Duration(minutesFromMidnight*60*1e9) * time.Nanosecond).
			In(loc)
		return &t
	}

	return SunTimes{
		Sunrise:   resolveAt(90.833, -1),
		Sunset:    resolveAt(90.833, +1),
		CivilDawn: resolveAt(96, -1),
		CivilDusk: resolveAt(96, +1),
	}
}

// ----- low-level helpers -----

func julianDate(t time.Time) float64 {
	return float64(t.UTC().Unix())/86400.0 + 2440587.5
}

func deg2rad(d float64) float64 { return d * math.Pi / 180 }
func rad2deg(r float64) float64 { return r * 180 / math.Pi }

// mod360 reduces an angle into [0, 360).
func mod360(d float64) float64 {
	r := math.Mod(d, 360)
	if r < 0 {
		r += 360
	}
	return r
}

// wrap180 wraps an angle into (-180, 180].
func wrap180(d float64) float64 {
	r := math.Mod(d+180, 360)
	if r < 0 {
		r += 360
	}
	return r - 180
}
