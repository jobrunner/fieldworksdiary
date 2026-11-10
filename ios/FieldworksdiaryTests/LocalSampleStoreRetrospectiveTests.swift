@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase N: samples entered afterwards. Their collecting day follows
/// the begin date; a field sample's day stays fixed.
@MainActor
final class LocalSampleStoreRetrospectiveTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        comps.timeZone = berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: comps)!
    }

    private func makeRetrospective(lat: Double? = 49.68123, lon: Double? = 10.03134) throws -> LocalSample {
        try store.createRetrospective(
            code: "Altfund 1", latitude: lat, longitude: lon,
            beginDate: date(2019, 5, 4, 10), timezone: "Europe/Berlin",
            timezoneSource: .locationService, mutationsStore: mutations
        )
    }

    private func markSynced(_ sample: LocalSample) throws {
        var s = sample
        s.backendId = "backend-1"
        try store.update(s)
    }

    func testCreateRetrospective_SetsDayFlagAndQueuesCreate() throws {
        let sample = try makeRetrospective()

        XCTAssertTrue(sample.isRetrospective)
        XCTAssertEqual(sample.collectingDay, "2019-05-04")
        XCTAssertEqual(sample.sampleID, "Altfund 1")
        XCTAssertEqual(sample.timezone, "Europe/Berlin")
        XCTAssertEqual(sample.locationSource, LocationSource.user.rawValue)
        XCTAssertEqual(sample.beginDate, date(2019, 5, 4, 10))
        XCTAssertEqual(sample.endDate, date(2019, 5, 4, 10).addingTimeInterval(15 * 60))
        let creates = try mutations.fetch(entityType: .sample).filter { $0.op == .create }
        XCTAssertEqual(creates.map(\.entityId), [sample.id])

        let location = SampleLocationFields(locationSource: .user, locationStatus: .pending)
        let body = SampleClient.createBody(SyncRunner.createInput(sample, location: location))
        XCTAssertEqual(body["is_retrospective"] as? Bool, true)
        XCTAssertEqual(body["collecting_day"] as? String, "2019-05-04")
    }

    func testCreateRetrospective_WithoutCoordinateWorks() throws {
        let sample = try makeRetrospective(lat: nil, lon: nil)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertNil(stored.latitude)
        XCTAssertNil(stored.longitude)
        XCTAssertTrue(stored.isRetrospective)
    }

    func testCreateRetrospective_DayUsesRollover() throws {
        // 03:00 Berlin lies before the 05:00 rollover → previous day.
        let sample = try store.createRetrospective(
            code: "x", latitude: nil, longitude: nil,
            beginDate: date(2019, 5, 4, 3), timezone: "Europe/Berlin",
            timezoneSource: .manual, mutationsStore: mutations
        )
        XCTAssertEqual(sample.collectingDay, "2019-05-03")
    }

    func testFieldSample_IsNotRetrospective() throws {
        let sample = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        XCTAssertFalse(sample.isRetrospective)
    }

    func testChangingBegin_OfRetrospective_FollowsDayAndUpdateCarriesIt() throws {
        let created = try makeRetrospective()
        try markSynced(created)
        var edit = try XCTUnwrap(store.fetchById(created.id))
        edit.beginDate = date(2019, 5, 5, 10)
        edit.endDate = date(2019, 5, 5, 10).addingTimeInterval(15 * 60)

        try store.saveEdits(edit, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(created.id))
        XCTAssertEqual(stored.collectingDay, "2019-05-05")
        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.count, 1)

        let location = SampleLocationFields(locationSource: .user, locationStatus: .pending)
        let body = SampleClient.updateBody(SampleUpdateInput(
            code: stored.sampleID, notes: nil, clientUuid: stored.id,
            clientUpdatedAt: stored.updatedAt, version: 2, location: location,
            timezone: stored.timezone, timezoneSource: stored.timezoneSource,
            collectingDay: stored.collectingDay, beginDate: stored.beginDate,
            endDate: stored.endDate, isAllDay: stored.isAllDay
        ))
        XCTAssertEqual(body["collecting_day"] as? String, "2019-05-05")
        XCTAssertNotNil(body["begin_date"])
        XCTAssertEqual(body["timezone"] as? String, "Europe/Berlin")
    }

    func testChangingZone_OfRetrospective_RecomputesDay() throws {
        let created = try makeRetrospective()
        var edit = try XCTUnwrap(store.fetchById(created.id))
        // 2019-05-04 10:00 Berlin (08:00 UTC) reads 22:00 on the 3rd in Honolulu.
        edit.timezone = "Pacific/Honolulu"
        try store.saveEdits(edit, mutationsStore: mutations)
        XCTAssertEqual(try XCTUnwrap(store.fetchById(created.id)).collectingDay, "2019-05-03")
    }

    func testAllDay_OfRetrospective_UsesCalendarDayWithoutRollover() throws {
        let created = try makeRetrospective()
        var edit = try XCTUnwrap(store.fetchById(created.id))
        edit.isAllDay = true
        edit.beginDate = date(2019, 5, 4, 0)
        edit.endDate = nil
        try store.saveEdits(edit, mutationsStore: mutations)
        XCTAssertEqual(try XCTUnwrap(store.fetchById(created.id)).collectingDay, "2019-05-04")
    }

    func testChangingBegin_OfFieldSample_KeepsDay() throws {
        let created = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        try markSynced(created)
        var edit = try XCTUnwrap(store.fetchById(created.id))
        edit.beginDate = date(2019, 5, 5, 10)

        try store.saveEdits(edit, mutationsStore: mutations)

        XCTAssertEqual(try XCTUnwrap(store.fetchById(created.id)).collectingDay, "2026-05-19")
    }

    func testHydration_TakesIsRetrospective() throws {
        let json = """
        {"id":"b1","sample_id":"Alt","fieldtrip":"ft","latitude":49.7,"longitude":10.0,
         "begin_date":"2019-05-04T08:00:00.000Z","timezone":"Europe/Berlin",
         "collecting_day":"2019-05-04","is_retrospective":true,"version":1,
         "client_uuid":"","location_source":"user"}
        """
        let remote = try JSONDecoder.fieldworks.decode(Sample.self, from: Data(json.utf8))
        XCTAssertTrue(remote.isRetrospective)

        try store.upsert([remote])

        let stored = try XCTUnwrap(store.fetchAll().first)
        XCTAssertTrue(stored.isRetrospective)
        XCTAssertEqual(stored.collectingDay, "2019-05-04")
    }

    func testMigrationV18_DefaultsToFalse() throws {
        let sample = try store.createLocal(lat: 1, lon: 2)
        let raw = try database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT is_retrospective FROM local_samples WHERE id = ?", arguments: [sample.id])
        }
        XCTAssertEqual(raw, false)
    }
}

@MainActor
final class CoordinateDisplayFormatConfigTests: XCTestCase {
    private let key = "AppConfig.coordinateDisplayFormat"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultIsDecimalSign() {
        XCTAssertEqual(AppConfig().coordinateDisplayFormat, .decimalSign)
    }

    func testChoicePersists() {
        AppConfig().coordinateDisplayFormat = .mgrs
        XCTAssertEqual(AppConfig().coordinateDisplayFormat, .mgrs)
    }

    func testUnknownStoredValueFallsBackToDefault() {
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(AppConfig().coordinateDisplayFormat, .decimalSign)
    }
}
