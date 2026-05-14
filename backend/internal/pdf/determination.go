package pdf

import (
	"fmt"
	"strings"
	"time"

	"github.com/jung-kurt/gofpdf"
)

// DeterminationLabel is what the determination template renders.
// One label corresponds to one (sample, determination) pair; the
// caller picks which determination per sample (typically the most
// recent `det.`).
type DeterminationLabel struct {
	Code         string
	SpeciesText  string
	Kind         string // "det", "t", "vid"
	PersonAbbrev string
	DeterminedOn time.Time
}

func RenderDeterminationLabels(labels []DeterminationLabel, layout Layout) ([]byte, error) {
	if len(labels) == 0 {
		return nil, fmt.Errorf("no labels to render")
	}
	style := styleFor(layout)
	drawAt := func(i int, pdf *gofpdf.Fpdf, x, y, w, h float64, tr func(string) string) {
		drawDeterminationCell(pdf, x, y, w, h, style, tr, labels[i])
	}
	switch layout {
	case LayoutMultiUpA4:
		return renderMultiUpA4(len(labels), drawAt)
	default:
		return renderA6Single(len(labels), drawAt)
	}
}

func drawDeterminationCell(pdf *gofpdf.Fpdf, x, y, w, h float64, style CellStyle, tr func(string) string, l DeterminationLabel) {
	bodyX := x + style.Padding
	bodyY := y + style.Padding
	contentW := w - 2*style.Padding

	// Species in italic — the visual cue of "this is the name".
	pdf.SetFont(style.BodyFont, "I", style.BodySize)
	pdf.SetXY(bodyX, bodyY)
	species := strings.TrimSpace(l.SpeciesText)
	if species == "" {
		species = "(ohne Bestimmung)"
	}
	pdf.MultiCell(contentW, style.LineHeight, tr(species), "", "L", false)

	// Kind + person + date in upright body font.
	pdf.SetFont(style.BodyFont, "", style.BodySize)
	for _, line := range determinationDetailLines(l) {
		pdf.SetX(bodyX)
		pdf.MultiCell(contentW, style.LineHeight, tr(line), "", "L", false)
	}

	pdf.SetFont(style.CodeFont, "B", style.CodeSize)
	pdf.SetXY(x+style.Padding, y+h-style.Padding-style.CodeSize*0.4)
	pdf.CellFormat(contentW, style.CodeSize*0.4, tr(l.Code), "", 0, "R", false, 0, "")
}

func determinationDetailLines(l DeterminationLabel) []string {
	var out []string

	// "det." / "t." / "vid." followed by the person abbreviation.
	short := shortKind(l.Kind)
	if short != "" {
		line := short
		if l.PersonAbbrev != "" {
			line = fmt.Sprintf("%s %s", short, l.PersonAbbrev)
		}
		out = append(out, line)
	} else if l.PersonAbbrev != "" {
		out = append(out, l.PersonAbbrev)
	}

	if !l.DeterminedOn.IsZero() {
		out = append(out, formatEntomologicalDate(l.DeterminedOn))
	}
	return out
}

func shortKind(k string) string {
	switch k {
	case "det":
		return "det."
	case "t":
		return "t."
	case "vid":
		return "vid."
	}
	return ""
}
