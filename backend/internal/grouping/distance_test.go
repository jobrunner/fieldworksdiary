package grouping

import (
	"math"
	"testing"
)

func TestHaversineMeters_KnownPairs(t *testing.T) {
	cases := []struct {
		name                   string
		lat1, lon1, lat2, lon2 float64
		want                   float64
		tol                    float64 // meters
	}{
		{
			"same point",
			49.7913, 9.9534, 49.7913, 9.9534,
			0, 0.1,
		},
		{
			// Würzburg → Frankfurt am Main (~97.6 km great-circle)
			"Würzburg → Frankfurt",
			49.7913, 9.9534, 50.1109, 8.6821,
			97_600, 2_000,
		},
		{
			// 1 degree of longitude at ~50°N is ~71.5 km
			"1 degree of longitude at 50°N",
			50.0, 0.0, 50.0, 1.0,
			71_500, 500,
		},
		{
			// 1 degree of latitude is ~111.2 km anywhere
			"1 degree of latitude",
			0.0, 0.0, 1.0, 0.0,
			111_200, 200,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := HaversineMeters(c.lat1, c.lon1, c.lat2, c.lon2)
			if math.Abs(got-c.want) > c.tol {
				t.Errorf("HaversineMeters = %.1f m, want %.1f ± %.1f m",
					got, c.want, c.tol)
			}
		})
	}
}

func TestNearestLocalityWithin_HappyPath(t *testing.T) {
	wuerzburg := LocalityCandidate{ID: "w", Name: "Würzburg", Lat: 49.7913, Lon: 9.9534, RadiusM: 1000}
	frankfurt := LocalityCandidate{ID: "f", Name: "Frankfurt", Lat: 50.1109, Lon: 8.6821, RadiusM: 5000}

	// A point right at the Würzburg centroid.
	got := NearestLocalityWithin(49.7913, 9.9534, []LocalityCandidate{frankfurt, wuerzburg})
	if got == nil || got.ID != "w" {
		t.Errorf("expected Würzburg, got %v", got)
	}

	// A point 200 m east of Würzburg — still inside its 1000 m radius.
	got = NearestLocalityWithin(49.7913, 9.956, []LocalityCandidate{frankfurt, wuerzburg})
	if got == nil || got.ID != "w" {
		t.Errorf("expected Würzburg from 200m east, got %v", got)
	}
}

func TestNearestLocalityWithin_BeyondRadiusReturnsNil(t *testing.T) {
	wuerzburg := LocalityCandidate{ID: "w", Name: "Würzburg", Lat: 49.7913, Lon: 9.9534, RadiusM: 100}
	// 1 km east — outside the 100 m radius.
	got := NearestLocalityWithin(49.7913, 9.9694, []LocalityCandidate{wuerzburg})
	if got != nil {
		t.Errorf("expected nil for point outside radius, got %v", got)
	}
}

func TestNearestLocalityWithin_TwoOverlappingPicksCloser(t *testing.T) {
	near := LocalityCandidate{ID: "a", Name: "Nah", Lat: 49.7913, Lon: 9.9534, RadiusM: 2000}
	far := LocalityCandidate{ID: "b", Name: "Fern", Lat: 49.7950, Lon: 9.9534, RadiusM: 2000} // ~411 m north of near

	got := NearestLocalityWithin(49.7920, 9.9534, []LocalityCandidate{far, near})
	if got == nil || got.ID != "a" {
		t.Errorf("expected closer locality 'a', got %v", got)
	}
}

func TestNearestLocalityWithin_IgnoresZeroRadius(t *testing.T) {
	bogus := LocalityCandidate{ID: "x", Name: "Bogus", Lat: 49.7913, Lon: 9.9534, RadiusM: 0}
	got := NearestLocalityWithin(49.7913, 9.9534, []LocalityCandidate{bogus})
	if got != nil {
		t.Errorf("expected nil for radius=0 candidate, got %v", got)
	}
}
