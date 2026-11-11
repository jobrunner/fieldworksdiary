@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// `LocalSampleFeatureStore.replace` swaps the complete feature set of
/// one sample, like the backend's `geoplace.ReplaceFeatures`.
final class LocalSampleFeatureStoreTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleFeatureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleFeatureStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try super.tearDownWithError()
    }

    private func feature(_ source: String, _ id: String, license: String? = nil) -> OrtusFeature {
        OrtusFeature(
            sourceID: source,
            sourceName: "Name \(source)",
            layer: "layer-\(source)",
            featureID: id,
            propertiesJSON: #"{"id":"\#(id)"}"#,
            licenseJSON: license
        )
    }

    func testReplace_InsertsAllFeatures() throws {
        try store.replace(sampleID: "s1", features: [
            feature("wdpa", "1", license: #"{"name":"CC-BY"}"#),
            feature("wdpa", "2"),
            feature("natura2000", "3")
        ])

        let wdpa = try store.features(sampleID: "s1", sourceID: "wdpa")
        XCTAssertEqual(wdpa.map(\.featureID), ["1", "2"])
        XCTAssertEqual(wdpa.first?.sourceName, "Name wdpa")
        XCTAssertEqual(wdpa.first?.layer, "layer-wdpa")
        XCTAssertEqual(wdpa.first?.propertiesJSON, #"{"id":"1"}"#)
        XCTAssertEqual(wdpa.first?.licenseJSON, #"{"name":"CC-BY"}"#)
        XCTAssertNil(wdpa.last?.licenseJSON)
        XCTAssertEqual(try store.features(sampleID: "s1", sourceID: "natura2000").count, 1)
    }

    func testReplace_ReplacesPreviousSetCompletely() throws {
        try store.replace(sampleID: "s1", features: [feature("wdpa", "1"), feature("natura2000", "2")])
        try store.replace(sampleID: "s1", features: [feature("wdpa", "9")])

        XCTAssertEqual(try store.features(sampleID: "s1", sourceID: "wdpa").map(\.featureID), ["9"])
        XCTAssertTrue(try store.features(sampleID: "s1", sourceID: "natura2000").isEmpty)
    }

    func testReplace_WithEmptyListClearsSample() throws {
        try store.replace(sampleID: "s1", features: [feature("wdpa", "1")])
        try store.replace(sampleID: "s1", features: [])

        XCTAssertTrue(try store.features(sampleID: "s1", sourceID: "wdpa").isEmpty)
    }

    func testReplace_LeavesOtherSamplesUntouched() throws {
        try store.replace(sampleID: "s1", features: [feature("wdpa", "1")])
        try store.replace(sampleID: "s2", features: [feature("wdpa", "2")])
        try store.replace(sampleID: "s1", features: [])

        XCTAssertEqual(try store.features(sampleID: "s2", sourceID: "wdpa").map(\.featureID), ["2"])
    }

    func testLocalSampleStoreReset_WipesFeatures() throws {
        try store.replace(sampleID: "s1", features: [feature("wdpa", "1")])
        let sampleStore = LocalSampleStore(database: database)

        try sampleStore.reset()

        XCTAssertTrue(try store.features(sampleID: "s1", sourceID: "wdpa").isEmpty)
    }
}
