// Package pdf renders sample labels into PDF bytes.
//
// Two layouts ship today:
//
//   - LayoutA6Single (default): one label per A6 page. Big text,
//     readable from arm's length, easy to crop.
//   - LayoutMultiUpA4: 4 × 8 grid on A4 portrait (32 labels per page).
//     Small text suited for cutting and gluing onto pin labels.
//
// New layouts plug in through `internal/pdf/layout.go`.
package pdf

import (
	"fmt"
	"strings"
	"time"

	"github.com/jung-kurt/gofpdf"
)

// SampleLabel is the data the locality template consumes.
type SampleLabel struct {
	Code            string
	Country         string
	AdminArea       string
	Locality        string
	Lat             float64
	Lon             float64
	HasCoords       bool
	AltitudeM       float64
	HasAltitude     bool
	CollectedFrom   time.Time
	CollectorAbbrev string
	MTBSheetNumber  string
	MTBSheetName    string
	PermitNumber    string
}

// RenderLocalityLabels writes a PDF with one label per `labels[i]`
// in the chosen layout.
func RenderLocalityLabels(labels []SampleLabel, layout Layout) ([]byte, error) {
	if len(labels) == 0 {
		return nil, fmt.Errorf("no labels to render")
	}
	style := styleFor(layout)
	drawAt := func(i int, pdf *gofpdf.Fpdf, x, y, w, h float64, tr func(string) string) {
		drawLocalityCell(pdf, x, y, w, h, style, tr, labels[i])
	}
	switch layout {
	case LayoutMultiUpA4:
		return renderMultiUpA4(len(labels), drawAt)
	default:
		return renderA6Single(len(labels), drawAt)
	}
}

func drawLocalityCell(pdf *gofpdf.Fpdf, x, y, w, h float64, style CellStyle, tr func(string) string, l SampleLabel) {
	pdf.SetFont(style.BodyFont, "", style.BodySize)
	bodyX := x + style.Padding
	bodyY := y + style.Padding
	pdf.SetXY(bodyX, bodyY)

	for _, line := range bodyLines(l) {
		pdf.SetX(bodyX)
		pdf.MultiCell(w-2*style.Padding, style.LineHeight, tr(line), "", "L", false)
	}

	// Code is bottom-right, monospaced. We pin it to the bottom edge
	// minus padding so it doesn't fight with the body lines for
	// vertical space — the body may wrap and grow, the code stays put.
	pdf.SetFont(style.CodeFont, "B", style.CodeSize)
	pdf.SetXY(x+style.Padding, y+h-style.Padding-style.CodeSize*0.4)
	pdf.CellFormat(w-2*style.Padding, style.CodeSize*0.4, tr(l.Code), "", 0, "R", false, 0, "")
}

func bodyLines(l SampleLabel) []string {
	var out []string

	loc := joinNonEmpty([]string{l.Country, l.AdminArea}, ", ")
	if loc != "" {
		out = append(out, loc)
	}
	if l.Locality != "" {
		out = append(out, l.Locality)
	}

	if l.HasCoords {
		coord := fmt.Sprintf("%.5f° N, %.5f° E", l.Lat, l.Lon)
		if l.HasAltitude {
			coord = fmt.Sprintf("%s, %.0f m", coord, l.AltitudeM)
		}
		out = append(out, coord)
	}

	if !l.CollectedFrom.IsZero() {
		date := formatEntomologicalDate(l.CollectedFrom)
		if l.CollectorAbbrev != "" {
			date = fmt.Sprintf("%s, leg. %s", date, l.CollectorAbbrev)
		}
		out = append(out, date)
	}

	if l.MTBSheetNumber != "" {
		mtb := "MTB " + l.MTBSheetNumber
		if l.MTBSheetName != "" {
			mtb = fmt.Sprintf("%s (%s)", mtb, l.MTBSheetName)
		}
		out = append(out, mtb)
	}

	if l.PermitNumber != "" {
		out = append(out, "Genehmigung "+l.PermitNumber)
	}

	return out
}

func joinNonEmpty(parts []string, sep string) string {
	var kept []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, sep)
}

// formatEntomologicalDate renders the date in the classic
// roman-numeral month convention: "12.V.2026".
func formatEntomologicalDate(t time.Time) string {
	months := []string{
		"", "I", "II", "III", "IV", "V", "VI",
		"VII", "VIII", "IX", "X", "XI", "XII",
	}
	return fmt.Sprintf("%d.%s.%d", t.Day(), months[t.Month()], t.Year())
}
