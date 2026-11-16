// Package mtb maps WGS84 coordinates onto the German TK25 map-sheet grid
// ("Messtischblatt") at quadrant precision.
package mtb

import "math"

// The TK25 grid used here is anchored at the north-west corner of the first
// cell: 55°54′ N (55.9°) and 5°50′ E (35/6°). Rows run southwards in steps of
// 0.1° (6′), columns run eastwards in steps of 1/6° (10′). Row and column
// numbers are 1-based.
const (
	gridOriginLat = 55.9
	gridOriginLon = 35.0 / 6.0
	rowStep       = 0.1
	colStep       = 1.0 / 6.0

	minLat = 47.0
	maxLat = 55.9
	minLon = 5.8334
	maxLon = 15.5
)

// Cell returns the TK25 row and column of the coordinate, plus the quadrant
// inside that cell: 1 = NW, 2 = NE, 3 = SW, 4 = SE. ok is false when the
// coordinate lies outside the covered area (47.0 ≤ lat ≤ 55.9,
// 5.8334 ≤ lon ≤ 15.5); the other return values are then meaningless.
func Cell(lat, lon float64) (row, col, quadrant int, ok bool) {
	if lat < minLat || lat > maxLat || lon < minLon || lon > maxLon {
		return 0, 0, 0, false
	}

	row = int(math.Floor((gridOriginLat-lat)/rowStep)) + 1
	col = int(math.Floor((lon-gridOriginLon)/colStep)) + 1

	// Mid-lines of the cell: the cell's north edge is one row step below the
	// origin per preceding row; the mid-latitude is half a row step further
	// south. Likewise for the west edge and the mid-longitude.
	cellNorth := gridOriginLat - float64(row-1)*rowStep
	cellWest := gridOriginLon + float64(col-1)*colStep
	midLat := cellNorth - rowStep/2
	midLon := cellWest + colStep/2

	north := lat > midLat
	west := lon < midLon

	switch {
	case north && west:
		quadrant = 1
	case north:
		quadrant = 2
	case west:
		quadrant = 3
	default:
		quadrant = 4
	}
	return row, col, quadrant, true
}
