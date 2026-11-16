package adminlabels

import (
	"strings"
	"testing"
)

// wikiArtifacts are fragments of the raw OSM-wiki draft that must not
// survive the curation pass, because terms are shown as UI field labels.
var wikiArtifacts = []string{"(", ")", "[[", "NUTS", "fixme", "derived from data", "n/a"}

func TestTerms_NoWikiArtifacts(t *testing.T) {
	for iso, c := range Default().Countries {
		for level, e := range c.Levels {
			if strings.TrimSpace(e.Term) == "" {
				t.Errorf("%s/%d: empty term", iso, level)
			}
			for _, a := range wikiArtifacts {
				if strings.Contains(e.Term, a) {
					t.Errorf("%s/%d: term %q contains %q", iso, level, e.Term, a)
				}
			}
		}
	}
}

func TestTerms_Samples(t *testing.T) {
	tb := Default()
	terms := []struct {
		iso   string
		level int
		want  string
	}{
		{"ES", 4, "Comunidad autónoma"},
		{"IT", 4, "Regione"},
		{"DE", 8, "Gemeinde"},
	}
	for _, tc := range terms {
		if got := tb.Term(tc.iso, tc.level); got != tc.want {
			t.Errorf("Term(%s,%d) = %q, want %q", tc.iso, tc.level, got, tc.want)
		}
	}
	if c, ok := tb.Column("IT", 4); !ok || c != "admin_state" {
		t.Errorf("Column(IT,4) = %q,%v, want admin_state", c, ok)
	}
}

func TestColumns_UniquePerCountry(t *testing.T) {
	valid := map[Tier]bool{}
	for _, tier := range Tiers {
		valid[tier] = true
	}
	for iso, c := range Default().Countries {
		seen := map[Tier]int{}
		for level, e := range c.Levels {
			if e.Column == nil {
				continue
			}
			if !valid[*e.Column] {
				t.Errorf("%s/%d: unknown column %q", iso, level, *e.Column)
			}
			if prev, dup := seen[*e.Column]; dup {
				t.Errorf("%s: column %q used by levels %d and %d", iso, *e.Column, prev, level)
			}
			seen[*e.Column] = level
		}
	}
}
