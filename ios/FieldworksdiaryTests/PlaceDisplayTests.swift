@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Display rules for place fields (Phase O2, Task 17): level order,
/// country-specific terms with generic fallback, hidden empty fields,
/// the short list name and the MTB line.
final class PlaceDisplayTests: XCTestCase {
    private let ochsenfurt = Place(
        countryISO: "DE",
        admin: [
            .municipality: AdminValue(name: "Ochsenfurt", level: 8),
            .country: AdminValue(name: "Deutschland", level: 2),
            .county: AdminValue(name: "Landkreis Würzburg", level: 6),
            .state: AdminValue(name: "Bayern", level: 4),
            .region: AdminValue(name: "", level: 5)
        ]
    )

    func testFields_AreInLevelOrderWithCountryTermsAndSkipEmpty() {
        let items = PlaceDisplay.fields(ochsenfurt)
        XCTAssertEqual(items.map(\.value), ["Deutschland", "Bayern", "Landkreis Würzburg", "Ochsenfurt"],
                       "level order, empty region hidden")
        XCTAssertEqual(items.map(\.term), ["Staat", "Bundesland", "Landkreis", "Gemeinde"])
        XCTAssertEqual(items[1].genericLabel, "Gliedstaat (1. Ebene)")
        XCTAssertEqual(items[2].genericLabel, "Kreis")
    }

    func testFields_LandscapeFieldsFollowAdminFields() {
        var place = Place(countryISO: "ES",
                          admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        place.island = "La Palma"
        place.mountain = "Roque de los Muchachos"
        let items = PlaceDisplay.fields(place)
        XCTAssertEqual(items.map(\.value), ["Garafía", "La Palma", "Roque de los Muchachos"])
        XCTAssertEqual(items[0].term, "Municipio")
        XCTAssertNil(items[1].term, "no country term for landscape fields")
        XCTAssertEqual(items[1].genericLabel, "Insel")
        XCTAssertEqual(items[2].genericLabel, "Berg")
    }

    func testFields_UnknownCountryFallsBackToGenericLabel() {
        let place = Place(countryISO: "ZZ", admin: [.state: AdminValue(name: "Nowhere", level: 4)])
        let item = try? XCTUnwrap(PlaceDisplay.fields(place).first)
        XCTAssertNil(item?.term)
        XCTAssertEqual(item?.genericLabel, "Gliedstaat (1. Ebene)")
        XCTAssertEqual(item?.displayTerm, "Gliedstaat (1. Ebene)")
    }

    func testGenericLabels_German() {
        let expected: [String: String] = [
            "admin.country": "Staat", "admin.state": "Gliedstaat (1. Ebene)", "admin.region": "Region",
            "admin.province": "Provinz", "admin.county": "Kreis", "admin.district": "Bezirk",
            "admin.municipality": "Gemeinde", "admin.borough": "Stadtbezirk", "admin.parish": "Kirchspiel",
            "admin.submunicipality": "Ortsteil", "admin.other": "Sonstige Einheit", "place.island": "Insel",
            "place.mountain_range": "Gebirge", "place.mountain": "Berg"
        ]
        for (key, value) in expected {
            XCTAssertEqual(PlaceDisplay.genericLabel(key), value, key)
        }
    }

    func testShortName_MunicipalityElseNextHigherFilledLevel() {
        XCTAssertEqual(PlaceDisplay.shortName(ochsenfurt), "Ochsenfurt")
        var noMunicipality = ochsenfurt
        noMunicipality.admin[.municipality] = nil
        XCTAssertEqual(PlaceDisplay.shortName(noMunicipality), "Landkreis Würzburg")
        let onlyCountry = Place(countryISO: "DE", admin: [.country: AdminValue(name: "Deutschland", level: 2)])
        XCTAssertEqual(PlaceDisplay.shortName(onlyCountry), "Deutschland")
        XCTAssertNil(PlaceDisplay.shortName(nil))
        XCTAssertNil(PlaceDisplay.shortName(Place(countryISO: "DE")))
    }

    func testMTBText() {
        XCTAssertEqual(PlaceDisplay.mtbText(number: "6326", name: "Ochsenfurt", quadrant: 1, countryISO: "DE"),
                       "MTB 6326/1 Ochsenfurt")
        XCTAssertEqual(PlaceDisplay.mtbText(number: "6326", name: "Ochsenfurt", quadrant: nil, countryISO: nil),
                       "MTB 6326 Ochsenfurt")
        XCTAssertNil(PlaceDisplay.mtbText(number: "6326", name: "X", quadrant: 1, countryISO: "AT"), "only DE")
        XCTAssertNil(PlaceDisplay.mtbText(number: nil, name: "X", quadrant: 1, countryISO: "DE"))
        XCTAssertNil(PlaceDisplay.mtbText(number: "", name: "X", quadrant: 1, countryISO: "DE"))
    }

    func testMatches_SearchesAllPlaceFieldsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "wurzburg"))
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "BAYERN"))
        XCTAssertFalse(PlaceDisplay.matches(ochsenfurt, query: "Tirol"))
        var palma = Place(countryISO: "ES")
        palma.mountainRange = "Caldera de Taburiente"
        XCTAssertTrue(PlaceDisplay.matches(palma, query: "taburiente"))
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "  "), "blank query matches")
    }

    // MARK: - sample view (Phase N)

    /// Admin data of `shared/testdata/ortus/expected_de_ochsenfurt.json`.
    private let ochsenfurtFixture = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .region: AdminValue(name: "Unterfranken", level: 5),
            .county: AdminValue(name: "Landkreis Würzburg", level: 6),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    func testGazetteerLine_DEFixture_CountryThenBroadToNarrow() {
        XCTAssertEqual(PlaceDisplay.gazetteerLine(ochsenfurtFixture),
                       "Deutschland, Bayern, Unterfranken, Landkreis Würzburg, Ochsenfurt")
    }

    func testGazetteerLine_SkipsMissingAndEmptyLevels() {
        var place = ochsenfurtFixture
        place.admin[.region] = nil
        place.admin[.municipality] = AdminValue(name: "  ", level: 8)
        XCTAssertEqual(PlaceDisplay.gazetteerLine(place), "Deutschland, Bayern, Landkreis Würzburg")
        // `ochsenfurt` has an empty region.
        XCTAssertEqual(PlaceDisplay.gazetteerLine(ochsenfurt), "Deutschland, Bayern, Landkreis Würzburg, Ochsenfurt")
    }

    func testGazetteerLine_CountryFromISOWithoutAdminCountry_NoLandscape() {
        var place = Place(countryISO: "ES", admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        place.island = "La Palma"
        XCTAssertEqual(PlaceDisplay.gazetteerLine(place), "Spanien, Garafía")
    }

    func testGazetteerLine_NilWithoutData() {
        XCTAssertNil(PlaceDisplay.gazetteerLine(nil))
        XCTAssertNil(PlaceDisplay.gazetteerLine(Place(countryISO: "")))
    }

    func testDetailLines_BearingAspectSlope_OnlyPresent() {
        let lines = PlaceDisplay.detailLines(
            bearingLabel: "2 km WNW Ochsenfurt", aspectCompass: "SSW", aspectDeg: 202.5,
            slopeDeg: 8.4, terrainFlat: false
        )
        XCTAssertEqual(lines.map(\.label), ["Peilung", "Exposition", "Hangneigung"])
        XCTAssertEqual(lines.map(\.value), ["2 km WNW Ochsenfurt", "SSW (203°)", "8°"])

        let onlyCompass = PlaceDisplay.detailLines(
            bearingLabel: nil, aspectCompass: "N", aspectDeg: nil, slopeDeg: nil, terrainFlat: false
        )
        XCTAssertEqual(onlyCompass, [PlaceDisplay.DetailLine(label: "Exposition", value: "N")])

        XCTAssertTrue(PlaceDisplay.detailLines(
            bearingLabel: " ", aspectCompass: nil, aspectDeg: nil, slopeDeg: nil, terrainFlat: false
        ).isEmpty)
    }

    func testDetailLines_FlatTerrainShowsEbenInsteadOfAspectAndSlope() {
        let lines = PlaceDisplay.detailLines(
            bearingLabel: "Ochsenfurt", aspectCompass: "SSW", aspectDeg: 202.5, slopeDeg: 0.4, terrainFlat: true
        )
        XCTAssertEqual(lines, [
            PlaceDisplay.DetailLine(label: "Peilung", value: "Ochsenfurt"),
            PlaceDisplay.DetailLine(label: nil, value: "eben")
        ])
    }

    func testCoordinate_FollowsDisplayFormat() {
        let decimal = PlaceDisplay.coordinate(latitude: 49.681230, longitude: 10.031340, format: .decimalSign)
        XCTAssertEqual(decimal.text, "+49.681230 +10.031340")
        XCTAssertEqual(decimal.caption, CoordinateDisplayFormat.decimalSign.title)

        let mgrs = PlaceDisplay.coordinate(latitude: 49.681230, longitude: 10.031340, format: .mgrs)
        XCTAssertTrue(mgrs.text.hasPrefix("32U NA 744"), mgrs.text)
        XCTAssertEqual(mgrs.caption, "MGRS")
    }

    func testCountryName_German() {
        XCTAssertEqual(PlaceDisplay.countryName("DE"), "Deutschland")
        XCTAssertEqual(PlaceDisplay.countryName("ES"), "Spanien")
    }
}
