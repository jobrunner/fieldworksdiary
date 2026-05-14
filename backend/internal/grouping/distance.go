package grouping

import "math"

// HaversineMeters returns the great-circle distance between two
// (lat, lon) points in meters. Mean Earth radius 6 371 000 m. The
// formula is exact enough for the locality-suggestion use case
// (sub-percent error at our latitudes).
func HaversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadiusM = 6371000.0
	phi1 := lat1 * math.Pi / 180
	phi2 := lat2 * math.Pi / 180
	dPhi := (lat2 - lat1) * math.Pi / 180
	dLambda := (lon2 - lon1) * math.Pi / 180

	a := math.Sin(dPhi/2)*math.Sin(dPhi/2) +
		math.Cos(phi1)*math.Cos(phi2)*math.Sin(dLambda/2)*math.Sin(dLambda/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return earthRadiusM * c
}

// LocalityCandidate is a slim view of a locality used by the
// nearest-match logic; the PocketBase-bound caller maps records into
// this shape.
type LocalityCandidate struct {
	ID      string
	Name    string
	Lat     float64
	Lon     float64
	RadiusM float64
}

// NearestLocalityWithin returns the locality whose centroid is
// closest to (lat, lon) AND within that locality's own radius. If no
// locality qualifies, returns nil. Ties broken by smallest distance,
// then alphabetical name.
func NearestLocalityWithin(lat, lon float64, candidates []LocalityCandidate) *LocalityCandidate {
	var best *LocalityCandidate
	bestDist := math.Inf(1)
	for i := range candidates {
		c := &candidates[i]
		if c.RadiusM <= 0 {
			continue
		}
		d := HaversineMeters(lat, lon, c.Lat, c.Lon)
		if d > c.RadiusM {
			continue
		}
		if d < bestDist || (d == bestDist && best != nil && c.Name < best.Name) {
			best = c
			bestDist = d
		}
	}
	return best
}
