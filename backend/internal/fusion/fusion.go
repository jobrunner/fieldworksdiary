// Package fusion holds the pure decision-logic for the server-side
// Locality-Fusion algorithm (Spec §5.2): given a newly-arrived
// Locality and the candidate set already in the DB, decide whether
// it stays alone, merges into exactly one neighbor, or sits in a
// review-needed state because two or more neighbors compete.
//
// Pure-Go on purpose. DB access (loading candidates, applying the
// decision, emitting the LocalityRemap event) lives in the
// `internal/hooks` adapter that wires this into PocketBase.
package fusion

import (
	"math"

	"go.mett.io/fwd-backend/internal/grouping"
)

// Candidate is the slim view the fusion algorithm cares about.
// `HorizontalAccuracy` is in metres; 0 means "unknown".
type Candidate struct {
	ID                 string
	Latitude           float64
	Longitude          float64
	HorizontalAccuracy float64
}

// DecisionKind enumerates the three possible outcomes per Spec §5.2.
type DecisionKind int

const (
	// KeepAsIs — no neighbor close enough; the incoming locality
	// stays standalone.
	KeepAsIs DecisionKind = iota
	// MergeInto — exactly one neighbor inside the adaptive radius.
	// The caller hangs the incoming locality's samples onto the
	// target, deletes the incoming row, and emits a LocalityRemap
	// event.
	MergeInto
	// FlagAmbiguous — two or more neighbors qualify. The incoming
	// locality stays, but the caller sets `needs_human_review=true`
	// so the UI can prompt the user.
	FlagAmbiguous
)

// Decision is the output of ServerFuse. `TargetID` is set when
// Kind == MergeInto; `AmbiguousIDs` lists every neighbor in the
// radius when Kind == FlagAmbiguous.
type Decision struct {
	Kind         DecisionKind
	TargetID     string
	AmbiguousIDs []string
	// RadiusM is the radius that was used to evaluate the
	// decision — exposed for diagnostics + tests, never read by
	// the hook.
	RadiusM float64
}

// MinRadius is the floor for the adaptive radius. Spec §5.2 hard-
// codes 50 m; configurable via `Settings.MinRadiusM` if a future
// tuning pass wants to bump it.
const MinRadius = 50.0

// Settings tunes the algorithm without re-compiling. Zero-valued
// `Settings{}` is the Spec-defaults shape (MinRadius=50).
type Settings struct {
	// MinRadiusM is the lower bound for the adaptive radius. If
	// 0, defaults to MinRadius (50 m).
	MinRadiusM float64
}

func (s Settings) minRadius() float64 {
	if s.MinRadiusM > 0 {
		return s.MinRadiusM
	}
	return MinRadius
}

// ServerFuse runs the Spec §5.2 algorithm:
//
//  1. Compute an adaptive radius
//     R = max(MinRadius,
//     2 * incoming.HorizontalAccuracy,
//     2 * max(c.HorizontalAccuracy for c in candidates))
//  2. Collect every candidate (excluding incoming itself) whose
//     centroid is within R metres (haversine).
//  3. Decide:
//     - 0 inside → KeepAsIs
//     - 1 inside → MergeInto
//     - 2+ inside → FlagAmbiguous
//
// The function is deterministic given the same inputs (no clock, no
// RNG); the result is reproducible across re-runs.
func ServerFuse(incoming Candidate, candidates []Candidate, settings Settings) Decision {
	radius := settings.minRadius()
	if r := 2 * incoming.HorizontalAccuracy; r > radius {
		radius = r
	}
	for _, c := range candidates {
		if r := 2 * c.HorizontalAccuracy; r > radius {
			radius = r
		}
	}

	inRadius := make([]Candidate, 0, len(candidates))
	for _, c := range candidates {
		if c.ID == incoming.ID {
			// Self — a re-fuse pass after a centroid update would
			// otherwise hit itself. Skip.
			continue
		}
		d := grouping.HaversineMeters(
			incoming.Latitude, incoming.Longitude,
			c.Latitude, c.Longitude,
		)
		if d <= radius {
			inRadius = append(inRadius, c)
		}
	}

	switch len(inRadius) {
	case 0:
		return Decision{Kind: KeepAsIs, RadiusM: radius}
	case 1:
		return Decision{Kind: MergeInto, TargetID: inRadius[0].ID, RadiusM: radius}
	default:
		ids := make([]string, len(inRadius))
		for i, c := range inRadius {
			ids[i] = c.ID
		}
		return Decision{Kind: FlagAmbiguous, AmbiguousIDs: ids, RadiusM: radius}
	}
}

// SignificantCoordChange reports whether the centroid has shifted
// enough that we should re-run the fusion. Spec §6.1 calls out
// 100 m as the threshold for re-geocoding; we re-use it here so the
// hook doesn't spam ServerFuse on every Set("notes", …)-type save.
func SignificantCoordChange(prevLat, prevLon, newLat, newLon float64) bool {
	const thresholdM = 100.0
	if prevLat == 0 && prevLon == 0 {
		// First time coords are set — definitely worth fusing.
		return newLat != 0 || newLon != 0
	}
	d := grouping.HaversineMeters(prevLat, prevLon, newLat, newLon)
	return d >= thresholdM
}

// Internal: round-trip guard for the radius computation when both
// the incoming and the candidate have horizontal-accuracy=0. We
// fall back to MinRadius then. `math` is imported for `Max` —
// keeping it here so the actual function reads cleanly.
var _ = math.Max
