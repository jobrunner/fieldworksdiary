@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase Z: the settings snapshot the store reads off the main actor.
final class SampleIDSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: "SampleIDSettingsTests")!
        defaults.removePersistentDomain(forName: "SampleIDSettingsTests")
    }

    func testUnsetFallsBackToDefaults() {
        let s = SampleIDSettings.current(defaults: defaults)
        XCTAssertEqual(s.format, SampleIDTemplate.default.raw)
        XCTAssertEqual(s.prefix, "")
        XCTAssertEqual(s.offset, 0)
        XCTAssertEqual(s.cutoffHour, 0)
        XCTAssertEqual(s.lastRunning, 0)
    }

    func testReadsStoredValuesAndClamps() {
        defaults.set("<PREFIX><n>", forKey: SampleIDSettings.Keys.format)
        defaults.set("X", forKey: SampleIDSettings.Keys.prefix)
        defaults.set(-4, forKey: SampleIDSettings.Keys.offset)
        defaults.set(99, forKey: SampleIDSettings.Keys.cutoffHour)
        defaults.set(12, forKey: SampleIDSettings.Keys.lastRunning)
        let s = SampleIDSettings.current(defaults: defaults)
        XCTAssertEqual(s.format, "<PREFIX><n>")
        XCTAssertEqual(s.prefix, "X")
        XCTAssertEqual(s.offset, 0)
        XCTAssertEqual(s.cutoffHour, 23)
        XCTAssertEqual(s.lastRunning, 12)
    }

    func testInvalidFormatFallsBackToDefault() {
        defaults.set("<seq><n>", forKey: SampleIDSettings.Keys.format)
        XCTAssertEqual(SampleIDSettings.current(defaults: defaults).format, SampleIDTemplate.default.raw)
    }
}
