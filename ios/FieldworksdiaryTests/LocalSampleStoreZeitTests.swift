import FieldworksGeo
@testable import Fieldworksdiary
import XCTest

/// Phase Z: time window, collecting day, sample-id suggestion and the
/// running counter in `LocalSampleStore.createLocal`.
final class LocalSampleStoreZeitTests: XCTestCase {
    private var database: Database!
    private var defaults: UserDefaults!
    // swiftlint:disable:next force_unwrapping
    private let canary = TimeZone(identifier: "Atlantic/Canary")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: "LocalSampleStoreZeitTests")!
        defaults.removePersistentDomain(forName: "LocalSampleStoreZeitTests")
    }

    private func makeStore(
        format: String = SampleIDTemplate.default.raw,
        prefix: String = "",
        cutoff: Int = 0,
        zone: TimeZone? = nil
    ) -> LocalSampleStore {
        LocalSampleStore(
            database: database, userId: "u1", timeZone: zone ?? canary, defaults: defaults,
            settings: {
                SampleIDSettings(
                    format: format, prefix: prefix, offset: 0, cutoffHour: cutoff,
                    lastRunning: self.defaults.integer(forKey: SampleIDSettings.Keys.lastRunning)
                )
            }
        )
    }

    private func date(_ iso: String) -> Date {
        // swiftlint:disable:next force_unwrapping
        ISO8601DateFormatter().date(from: iso)!
    }

    func testCreateLocal_SetsZoneWindowAndCollectingDay() throws {
        let store = makeStore()
        // 23:50 in Canary (UTC+0 in January) with rollover 0 → same calendar day.
        let at = date("2026-01-15T23:53:20Z")
        let s = try store.createLocal(lat: 28.1, lon: -15.4, collectedFrom: at)
        XCTAssertEqual(s.timezone, "Atlantic/Canary")
        XCTAssertEqual(s.timezoneSource, .device)
        let window = SampleTime.defaultWindow(createdAt: at, in: canary)
        XCTAssertEqual(s.beginDate, window.begin)
        XCTAssertEqual(s.endDate, window.end)
        XCTAssertEqual(s.collectingDay, "2026-01-15")
        XCTAssertEqual(s.sampleID, "260115/1")
    }

    func testCreateLocal_UsesConfiguredRollover() throws {
        let store = makeStore(cutoff: 5)
        let s = try store.createLocal(lat: 28.1, lon: -15.4, collectedFrom: date("2026-01-16T03:00:00Z"))
        XCTAssertEqual(s.collectingDay, "2026-01-15")
    }

    func testEmptyID_IsStoredAndNeverFound() throws {
        let store = makeStore()
        let a = try store.createLocal(lat: 1, lon: 1, overrideCode: "")
        let b = try store.createLocal(lat: 1, lon: 1, overrideCode: "")
        XCTAssertEqual(a.sampleID, "")
        XCTAssertEqual(b.sampleID, "")
        XCTAssertNil(try store.findByCode(""))
    }

    func testEmptyTemplate_SuggestsEmptyID() throws {
        let store = makeStore(format: SampleIDTemplate.empty.raw)
        XCTAssertEqual(store.peekNextCode(), "")
        XCTAssertEqual(try store.createLocal(lat: 1, lon: 1).sampleID, "")
    }

    func testRunningCounter_AdvancesOnlyForUnchangedSuggestion() throws {
        let store = makeStore(format: "<PREFIX><n>", prefix: "K")
        XCTAssertEqual(store.peekNextCode(), "K1")
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 0, "peek has no side effect")

        _ = try store.createLocal(lat: 1, lon: 1) // suggestion taken as is
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 1)

        _ = try store.createLocal(lat: 1, lon: 1, overrideCode: "own-7") // edited
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 1)
        XCTAssertEqual(store.peekNextCode(), "K2")
    }
}
