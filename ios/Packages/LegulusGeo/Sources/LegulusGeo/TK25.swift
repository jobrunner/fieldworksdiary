import Foundation

/// Maps WGS84 coordinates onto the German TK25 map-sheet grid at quadrant
/// precision. Port of Go `mtb.Cell`; the arithmetic is kept identical so
/// boundary cases match bit-for-bit.
public enum TK25 {
    private static let gridOriginLat = 55.9
    private static let gridOriginLon = 35.0 / 6.0
    private static let rowStep = 0.1
    private static let colStep = 1.0 / 6.0
    private static let minLat = 47.0
    private static let maxLat = 55.9
    private static let minLon = 5.8334
    private static let maxLon = 15.5

    /// Row, column (1-based) and quadrant (1 = NW, 2 = NE, 3 = SW, 4 = SE),
    /// or nil outside the covered area.
    public static func cell(lat: Double, lon: Double) -> (row: Int, col: Int, quadrant: Int)? {
        if lat < minLat || lat > maxLat || lon < minLon || lon > maxLon { return nil }

        let row = Int(((gridOriginLat - lat) / rowStep).rounded(.down)) + 1
        let col = Int(((lon - gridOriginLon) / colStep).rounded(.down)) + 1

        let cellNorth = gridOriginLat - Double(row - 1) * rowStep
        let cellWest = gridOriginLon + Double(col - 1) * colStep
        let midLat = cellNorth - rowStep / 2
        let midLon = cellWest + colStep / 2

        let north = lat > midLat
        let west = lon < midLon
        let quadrant: Int
        switch (north, west) {
        case (true, true): quadrant = 1
        case (true, false): quadrant = 2
        case (false, true): quadrant = 3
        case (false, false): quadrant = 4
        }
        return (row, col, quadrant)
    }
}
