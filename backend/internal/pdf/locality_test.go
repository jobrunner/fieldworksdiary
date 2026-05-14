package pdf

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestBodyLines_FullData(t *testing.T) {
	l := SampleLabel{
		Code:            "260510/3",
		Country:         "Deutschland",
		AdminArea:       "Bayern",
		Locality:        "Würzburg",
		Lat:             49.7913,
		Lon:             9.9534,
		HasCoords:       true,
		AltitudeM:       280,
		HasAltitude:     true,
		CollectedFrom:   time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC),
		CollectorAbbrev: "J. Brunner",
		MTBSheetNumber:  "6225",
		MTBSheetName:    "Würzburg Süd",
		PermitNumber:    "BV-2026/123",
	}
	got := bodyLines(l)
	want := []string{
		"Deutschland, Bayern",
		"Würzburg",
		"49.79130° N, 9.95340° E, 280 m",
		"12.V.2026, leg. J. Brunner",
		"MTB 6225 (Würzburg Süd)",
		"Genehmigung BV-2026/123",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d lines, want %d: %v", len(got), len(want), got)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestBodyLines_MinimalData(t *testing.T) {
	l := SampleLabel{Code: "260510/1"}
	got := bodyLines(l)
	if len(got) != 0 {
		t.Errorf("expected empty body when no fields set, got %v", got)
	}
}

func TestBodyLines_NoAltitude(t *testing.T) {
	l := SampleLabel{
		Lat:           49.79, Lon: 9.95, HasCoords: true,
		HasAltitude:   false,
		CollectedFrom: time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC),
	}
	got := bodyLines(l)
	if !strings.Contains(got[0], "° N") {
		t.Errorf("expected coordinates line, got %q", got[0])
	}
	if strings.Contains(got[0], "m") {
		t.Errorf("unexpected altitude in line: %q", got[0])
	}
}

func TestFormatEntomologicalDate(t *testing.T) {
	cases := []struct {
		t    time.Time
		want string
	}{
		{time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), "1.I.2026"},
		{time.Date(2026, 5, 12, 0, 0, 0, 0, time.UTC), "12.V.2026"},
		{time.Date(2025, 12, 31, 0, 0, 0, 0, time.UTC), "31.XII.2025"},
	}
	for _, c := range cases {
		if got := formatEntomologicalDate(c.t); got != c.want {
			t.Errorf("formatEntomologicalDate(%v) = %q, want %q", c.t, got, c.want)
		}
	}
}

func TestRenderLocalityLabels_ProducesPDF(t *testing.T) {
	labels := []SampleLabel{{
		Code: "260510/3", Country: "Deutschland", AdminArea: "Bayern",
		Locality: "Würzburg", Lat: 49.7913, Lon: 9.9534, HasCoords: true,
		CollectedFrom: time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC),
	}}
	data, err := RenderLocalityLabels(labels, LayoutA6Single)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if len(data) < 200 {
		t.Errorf("PDF suspiciously small: %d bytes", len(data))
	}
	if !strings.HasPrefix(string(data[:5]), "%PDF-") {
		t.Errorf("not a PDF file, first bytes: %q", data[:5])
	}
}

func TestRenderLocalityLabels_EmptyErrors(t *testing.T) {
	_, err := RenderLocalityLabels(nil, LayoutA6Single)
	if err == nil {
		t.Error("expected error for empty input")
	}
}

func TestRenderLocalityLabels_MultiUpA4_ProducesPDF(t *testing.T) {
	var labels []SampleLabel
	for i := 0; i < 35; i++ { // > 32 to force a second page
		labels = append(labels, SampleLabel{
			Code:    fmt.Sprintf("260512/%d", i+1),
			Country: "Deutschland", AdminArea: "Bayern", Locality: "Würzburg",
			Lat: 49.7913, Lon: 9.9534, HasCoords: true,
			CollectedFrom: time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC),
		})
	}
	data, err := RenderLocalityLabels(labels, LayoutMultiUpA4)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if len(data) < 500 {
		t.Errorf("PDF suspiciously small: %d bytes", len(data))
	}
}

func TestRenderDeterminationLabels_RendersAllKinds(t *testing.T) {
	labels := []DeterminationLabel{
		{Code: "260512/1", SpeciesText: "Otiorhynchus ligustici", Kind: "det",
			PersonAbbrev: "J. Brunner",
			DeterminedOn: time.Date(2026, 5, 12, 0, 0, 0, 0, time.UTC)},
		{Code: "260512/2", SpeciesText: "Curculio nucum", Kind: "vid"},
	}
	data, err := RenderDeterminationLabels(labels, LayoutA6Single)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if !strings.HasPrefix(string(data[:5]), "%PDF-") {
		t.Errorf("not a PDF: %q", data[:5])
	}
}

func TestDeterminationDetailLines(t *testing.T) {
	l := DeterminationLabel{
		Kind: "det", PersonAbbrev: "J. Brunner",
		DeterminedOn: time.Date(2026, 5, 12, 0, 0, 0, 0, time.UTC),
	}
	lines := determinationDetailLines(l)
	if len(lines) != 2 {
		t.Fatalf("got %d lines: %v", len(lines), lines)
	}
	if lines[0] != "det. J. Brunner" {
		t.Errorf("line 0 = %q", lines[0])
	}
	if lines[1] != "12.V.2026" {
		t.Errorf("line 1 = %q", lines[1])
	}
}

func TestShortKind(t *testing.T) {
	cases := map[string]string{"det": "det.", "t": "t.", "vid": "vid.", "xxx": ""}
	for in, want := range cases {
		if got := shortKind(in); got != want {
			t.Errorf("shortKind(%q) = %q, want %q", in, got, want)
		}
	}
}
