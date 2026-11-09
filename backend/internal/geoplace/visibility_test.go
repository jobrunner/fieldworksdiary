package geoplace

import (
	"testing"

	"github.com/pocketbase/pocketbase/models"
)

func pmRec(owner, source string) *models.Record {
	coll := &models.Collection{Name: "placemarks"}
	r := models.NewRecord(coll)
	r.Set("owner", owner)
	r.Set("geocoding_source", source)
	return r
}

func TestVisibleTo(t *testing.T) {
	cases := []struct {
		name          string
		owner, source string
		user          string
		want          bool
	}{
		{"shared backend row", "", SourceBackendService, "u1", true},
		{"orphaned manual row", "", SourceManual, "u1", false},
		{"own manual row", "u1", SourceManual, "u1", true},
		{"foreign manual row", "u2", SourceManual, "u1", false},
		{"owned backend row foreign", "u2", SourceBackendService, "u1", false},
		{"anonymous caller own-less", "u1", SourceManual, "", false},
		{"nil record", "", "", "u1", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var r *models.Record
			if c.name != "nil record" {
				r = pmRec(c.owner, c.source)
			}
			if got := VisibleTo(r, c.user); got != c.want {
				t.Errorf("VisibleTo = %v, want %v", got, c.want)
			}
		})
	}
}
