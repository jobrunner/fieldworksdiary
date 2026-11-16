package mtb

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type tk25Case struct {
	Lat      float64 `json:"lat"`
	Lon      float64 `json:"lon"`
	Row      int     `json:"row"`
	Col      int     `json:"col"`
	Quadrant int     `json:"quadrant"`
	OK       *bool   `json:"ok"`
}

func TestCell_SharedCases(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "tk25_cases.json"))
	if err != nil {
		t.Fatalf("read shared cases: %v", err)
	}
	var cases []tk25Case
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatalf("parse shared cases: %v", err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases loaded")
	}
	for i, c := range cases {
		wantOK := c.OK == nil || *c.OK
		row, col, quad, ok := Cell(c.Lat, c.Lon)
		if ok != wantOK {
			t.Errorf("case %d (%v,%v): ok = %v, want %v", i, c.Lat, c.Lon, ok, wantOK)
			continue
		}
		if !wantOK {
			continue
		}
		if row != c.Row || col != c.Col || quad != c.Quadrant {
			t.Errorf("case %d (%v,%v): got row=%d col=%d quad=%d, want row=%d col=%d quad=%d",
				i, c.Lat, c.Lon, row, col, quad, c.Row, c.Col, c.Quadrant)
		}
	}
}
