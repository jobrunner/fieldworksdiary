package pdf

import (
	"bytes"
	"fmt"

	"github.com/jung-kurt/gofpdf"
)

// Layout picks between the one-per-A6 page (default) and the
// many-per-A4 grid (multi-up).
type Layout int

const (
	LayoutA6Single Layout = iota
	LayoutMultiUpA4
)

// LayoutFromTemplate maps the template-name parameter on the HTTP
// endpoint to a Layout. Unknown values fall back to A6 single.
func LayoutFromTemplate(name string) Layout {
	switch name {
	case "multi-up-a4", "a4-multi", "a4":
		return LayoutMultiUpA4
	default:
		return LayoutA6Single
	}
}

// CellStyle bundles the typography parameters a label cell needs.
// Two presets cover today's templates; new ones (e.g. small Avery
// sheets) drop in with their own struct.
type CellStyle struct {
	BodyFont   string
	BodySize   float64
	CodeFont   string
	CodeSize   float64
	LineHeight float64
	Padding    float64 // inner margin within the cell
}

var (
	StyleA6Single = CellStyle{
		BodyFont:   "Helvetica",
		BodySize:   8,
		CodeFont:   "Courier",
		CodeSize:   10,
		LineHeight: 4,
		Padding:    5,
	}
	StyleMultiUpA4 = CellStyle{
		BodyFont:   "Helvetica",
		BodySize:   6,
		CodeFont:   "Courier",
		CodeSize:   7,
		LineHeight: 2.6,
		Padding:    1.5,
	}
)

// renderA6Single draws one label per A6 page.
func renderA6Single(count int, draw func(int, *gofpdf.Fpdf, float64, float64, float64, float64, func(string) string)) ([]byte, error) {
	if count == 0 {
		return nil, fmt.Errorf("no labels to render")
	}
	pdf := gofpdf.New("P", "mm", "A6", "")
	pdf.SetMargins(StyleA6Single.Padding, StyleA6Single.Padding, StyleA6Single.Padding)
	pdf.SetAutoPageBreak(false, 0)
	tr := pdf.UnicodeTranslatorFromDescriptor("")

	// A6 inner box: 105 × 148 mm minus 5 mm margin = 95 × 138 mm
	const innerW = 105 - 2*5
	const innerH = 148 - 2*5

	for i := 0; i < count; i++ {
		pdf.AddPage()
		draw(i, pdf, 5, 5, innerW, innerH, tr)
	}
	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, fmt.Errorf("pdf output: %w", err)
	}
	return buf.Bytes(), nil
}

// renderMultiUpA4 draws labels in a 4 × 8 grid on A4 portrait. The
// optional cell border helps the user cut precisely.
func renderMultiUpA4(count int, draw func(int, *gofpdf.Fpdf, float64, float64, float64, float64, func(string) string)) ([]byte, error) {
	if count == 0 {
		return nil, fmt.Errorf("no labels to render")
	}
	pdf := gofpdf.New("P", "mm", "A4", "")
	pdf.SetMargins(10, 10, 10)
	pdf.SetAutoPageBreak(false, 0)
	tr := pdf.UnicodeTranslatorFromDescriptor("")

	const (
		pageW  = 210.0
		pageH  = 297.0
		margin = 10.0
		cols   = 4
		rows   = 8
		innerW = pageW - 2*margin
		innerH = pageH - 2*margin
		cellW  = innerW / cols
		cellH  = innerH / rows
	)

	pdf.AddPage()
	pdf.SetDrawColor(220, 220, 220)
	pdf.SetLineWidth(0.1)

	for i := 0; i < count; i++ {
		slot := i % (cols * rows)
		if i > 0 && slot == 0 {
			pdf.AddPage()
		}
		col := slot % cols
		row := slot / cols
		x := margin + float64(col)*cellW
		y := margin + float64(row)*cellH
		pdf.Rect(x, y, cellW, cellH, "D")
		draw(i, pdf, x, y, cellW, cellH, tr)
	}
	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, fmt.Errorf("pdf output: %w", err)
	}
	return buf.Bytes(), nil
}

// styleFor returns the typography preset for the given layout.
func styleFor(l Layout) CellStyle {
	if l == LayoutMultiUpA4 {
		return StyleMultiUpA4
	}
	return StyleA6Single
}
