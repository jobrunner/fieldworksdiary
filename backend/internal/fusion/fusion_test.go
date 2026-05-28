package fusion

import (
	"testing"
)

// Most fixtures sit around Würzburg so the latitudes are realistic
// for the actual data (49.79° N → 1° longitude ≈ 71 km).

func cand(id string, lat, lon, hAcc float64) Candidate {
	return Candidate{
		ID:                 id,
		Latitude:           lat,
		Longitude:          lon,
		HorizontalAccuracy: hAcc,
	}
}

func TestServerFuse_NoCandidates_KeepAsIs(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	d := ServerFuse(incoming, nil, Settings{})
	if d.Kind != KeepAsIs {
		t.Errorf("Kind = %v, want KeepAsIs", d.Kind)
	}
	if d.RadiusM != MinRadius {
		t.Errorf("RadiusM = %v, want %v", d.RadiusM, MinRadius)
	}
}

func TestServerFuse_SingleClose_MergeInto(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	// ~30 m east of incoming at this latitude.
	target := cand("t", 49.79, 9.94042, 0)
	d := ServerFuse(incoming, []Candidate{target}, Settings{})
	if d.Kind != MergeInto {
		t.Fatalf("Kind = %v, want MergeInto", d.Kind)
	}
	if d.TargetID != "t" {
		t.Errorf("TargetID = %q, want t", d.TargetID)
	}
}

func TestServerFuse_SingleFar_KeepAsIs(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	// ~200 m east.
	far := cand("t", 49.79, 9.9428, 0)
	d := ServerFuse(incoming, []Candidate{far}, Settings{})
	if d.Kind != KeepAsIs {
		t.Errorf("Kind = %v, want KeepAsIs", d.Kind)
	}
}

func TestServerFuse_TwoClose_FlagAmbiguous(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	a := cand("a", 49.79, 9.94042, 0)  // ~30 m east
	b := cand("b", 49.79, 9.939589, 0) // ~30 m west
	d := ServerFuse(incoming, []Candidate{a, b}, Settings{})
	if d.Kind != FlagAmbiguous {
		t.Fatalf("Kind = %v, want FlagAmbiguous", d.Kind)
	}
	if len(d.AmbiguousIDs) != 2 {
		t.Errorf("AmbiguousIDs = %v, want length 2", d.AmbiguousIDs)
	}
}

func TestServerFuse_AdaptiveRadius_HighAccuracyTriggersMerge(t *testing.T) {
	// Incoming has 80 m accuracy → R = max(50, 160, 0) = 160 m.
	// A candidate 150 m away should now qualify.
	incoming := cand("in", 49.79, 9.94, 80)
	far := cand("t", 49.79, 9.9421, 0) // ~150 m east
	d := ServerFuse(incoming, []Candidate{far}, Settings{})
	if d.Kind != MergeInto {
		t.Errorf("Kind = %v, want MergeInto (R should be 160 m, candidate 150 m away)", d.Kind)
	}
	if d.RadiusM != 160.0 {
		t.Errorf("RadiusM = %v, want 160", d.RadiusM)
	}
}

func TestServerFuse_AdaptiveRadius_CandidateAccuracyAlsoCounts(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	// Candidate itself has hAcc=100 → R = max(50, 0, 200) = 200.
	far := cand("t", 49.79, 9.9421, 100) // ~150 m east
	d := ServerFuse(incoming, []Candidate{far}, Settings{})
	if d.Kind != MergeInto {
		t.Errorf("Kind = %v, want MergeInto (candidate's hAcc=100 inflates R to 200)", d.Kind)
	}
	if d.RadiusM != 200.0 {
		t.Errorf("RadiusM = %v, want 200", d.RadiusM)
	}
}

func TestServerFuse_SelfExcluded(t *testing.T) {
	// Re-running the fusion on a locality that's already in the DB
	// would otherwise match itself at 0 m.
	incoming := cand("in", 49.79, 9.94, 0)
	self := cand("in", 49.79, 9.94, 0)
	other := cand("other", 49.80, 9.95, 0) // far away
	d := ServerFuse(incoming, []Candidate{self, other}, Settings{})
	if d.Kind != KeepAsIs {
		t.Errorf("Kind = %v, want KeepAsIs (self must be excluded)", d.Kind)
	}
}

func TestServerFuse_CustomMinRadius(t *testing.T) {
	incoming := cand("in", 49.79, 9.94, 0)
	c := cand("c", 49.79, 9.94042, 0) // ~30 m east
	// Tighten the floor to 10 m — the 30 m candidate drops out.
	d := ServerFuse(incoming, []Candidate{c}, Settings{MinRadiusM: 10})
	if d.Kind != KeepAsIs {
		t.Errorf("Kind = %v, want KeepAsIs with tightened R", d.Kind)
	}
}

func TestSignificantCoordChange(t *testing.T) {
	cases := []struct {
		name                             string
		prevLat, prevLon, newLat, newLon float64
		want                             bool
	}{
		{"first set from 0,0", 0, 0, 49.79, 9.94, true},
		{"unchanged", 49.79, 9.94, 49.79, 9.94, false},
		// ~30 m apart — below the 100 m threshold.
		{"sub-threshold drift", 49.79, 9.94, 49.79, 9.94042, false},
		// ~150 m apart.
		{"clear shift", 49.79, 9.94, 49.79, 9.9421, true},
		// Still at zero — never set.
		{"both zero", 0, 0, 0, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := SignificantCoordChange(c.prevLat, c.prevLon, c.newLat, c.newLon)
			if got != c.want {
				t.Errorf("got %v, want %v", got, c.want)
			}
		})
	}
}
