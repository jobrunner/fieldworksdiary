@testable import Fieldworksdiary
import XCTest

/// Tests für die zentrale Persistierungs-Logik. Läuft gegen eine
/// in-memory GRDB-DB — siehe `Database.init(inMemory:)`.
final class LocalSampleStoreTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "user-a", cutoffHour: 5, timeZone: berlin)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - createLocal

    func testCreateLocal_AssignsSequenceOneOnFirstCall() throws {
        let sample = try store.createLocal(
            lat: 49.79,
            lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        XCTAssertEqual(sample.sampleID, "260519/1")
        XCTAssertEqual(sample.syncStatus, .pending)
        XCTAssertEqual(sample.userId, "user-a")
        XCTAssertNil(sample.backendId)
    }

    func testCreateLocal_IncrementsSequenceForSameDay() throws {
        _ = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        let second = try store.createLocal(lat: 49.80, lon: 9.95, collectedFrom: date(2026, 5, 19, 15))
        XCTAssertEqual(second.sampleID, "260519/2")
    }

    func testCreateLocal_DifferentDaysHaveSeparateSequences() throws {
        let day1 = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        let day2 = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 20, 14))
        XCTAssertEqual(day1.sampleID, "260519/1")
        XCTAssertEqual(day2.sampleID, "260520/1")
    }

    func testCreateLocal_RespectsCutoffHour_BelongsToPreviousDay() throws {
        // 03:00 liegt vor dem 5-Uhr-Cutoff → Code für Vortag (18.05.).
        let sample = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 3)
        )
        XCTAssertEqual(sample.sampleID, "260518/1")
        XCTAssertEqual(sample.collectingDay, "2026-05-18")
    }

    // MARK: - upsert

    func testUpsert_InsertsFreshSampleWhenNoMatch() throws {
        let remote = makeRemoteSample(id: "backend-1", code: "260519/5", clientUuid: nil)
        try store.upsert([remote])

        let stored = try database.reader.read { db in
            try LocalSample.fetchAll(db)
        }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].backendId, "backend-1")
        XCTAssertEqual(stored[0].sampleID, "260519/5")
        XCTAssertEqual(stored[0].syncStatus, .synced)
    }

    func testUpsert_MatchesByClientUuid() throws {
        // Erst lokal anlegen (UUID = local.id, syncStatus = .pending).
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        // Push fertig — markiere als synced damit upsert nicht skipped.
        var updated = local
        updated.syncStatus = .synced
        try store.update(updated)

        // Server schickt das Sample mit clientUuid = local.id zurück.
        let remote = makeRemoteSample(id: "backend-abc", code: local.sampleID, clientUuid: local.id)
        try store.upsert([remote])

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.backendId, "backend-abc", "should update existing row by client_uuid match")

        let total = try database.reader.read { db in try LocalSample.fetchCount(db) }
        XCTAssertEqual(total, 1, "should not insert a duplicate")
    }

    func testUpsert_SkipsPendingRows() throws {
        // Local row ist .pending → Server-Update soll es NICHT überschreiben.
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        XCTAssertEqual(local.syncStatus, .pending)

        // Server-seitige Reassignment (simulieren wir).
        let remote = makeRemoteSample(id: "backend-xyz", code: "260519/99", clientUuid: local.id)
        try store.upsert([remote])

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertNil(stored.backendId, "pending row must not be overwritten by upsert")
        XCTAssertEqual(stored.sampleID, local.sampleID, "code must not change while push in flight")
    }

    func testUpsert_AppliesServerCodeReassignmentAsBackendCode() throws {
        // Lokal mit Code /1 gespeichert, dann gesynct, Server hat
        // beim Push auf /7 umgemappt.
        var local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        local.syncStatus = .synced
        try store.update(local)

        let remote = makeRemoteSample(
            id: "backend-1",
            code: "260519/7",
            originalCode: local.sampleID,
            clientUuid: local.id
        )
        try store.upsert([remote])

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.sampleID, "260519/1", "local code (= auf Röhrchen) bleibt erhalten")
        XCTAssertEqual(stored.backendCode, "260519/7", "Server-Reassignment landet in backendCode")
        XCTAssertEqual(stored.originalCode, "260519/1", "Audit-Trail: was auf der Röhre stand")
    }

    func testUpsert_BumpsSequenceFromHydratedCode() throws {
        // Wir empfangen ein Sample vom Server mit Code /5 — die lokale
        // Sequenz muss danach mindestens auf 5 stehen, sonst kollidiert
        // ein lokaler createLocal-Call.
        let remote = makeRemoteSample(id: "backend-1", code: "260519/5", clientUuid: nil)
        try store.upsert([remote])

        let next = try store.createLocal(
            lat: 50.0, lon: 10.0,
            collectedFrom: date(2026, 5, 19, 16)
        )
        XCTAssertEqual(next.sampleID, "260519/6", "Sequenz nach Hydrate hochgezogen")
    }

    // MARK: - reset

    func testReset_WipesSamplesAndSequences() throws {
        _ = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        _ = try store.createLocal(lat: 49.80, lon: 9.95, collectedFrom: date(2026, 5, 19, 15))

        try store.reset()

        let totalSamples = try database.reader.read { db in try LocalSample.fetchCount(db) }
        XCTAssertEqual(totalSamples, 0)

        // Sequenz darf nach reset auf /1 anfangen, nicht auf /3.
        let fresh = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        XCTAssertEqual(fresh.sampleID, "260519/1", "Sequenz nach reset zurückgesetzt")
    }

    // MARK: - fetchPending

    func testFetchPending_ReturnsPendingAndFailedNotSynced() throws {
        let pending = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 14))
        let synced = try store.createLocal(lat: 49.80, lon: 9.95, collectedFrom: date(2026, 5, 19, 15))
        let failed = try store.createLocal(lat: 49.81, lon: 9.96, collectedFrom: date(2026, 5, 19, 16))

        var syncedCopy = synced
        syncedCopy.syncStatus = .synced
        try store.update(syncedCopy)

        var failedCopy = failed
        failedCopy.syncStatus = .failed
        try store.update(failedCopy)

        let result = try store.fetchPending()
        let ids = result.map(\.id).sorted()
        let want = [pending.id, failed.id].sorted()
        XCTAssertEqual(ids, want)
    }

    // MARK: - helpers

    // MARK: - elevation / latestPlacemarkID

    func testCreateLocal_StoresElevationAndPendingLocationStatus() throws {
        let sample = try store.createLocal(lat: 49.79, lon: 9.94, elevation: 180, collectedFrom: date(2026, 5, 19, 14))
        let reloaded = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(reloaded.elevation, 180)
        XCTAssertEqual(reloaded.locationStatus, .pending)
    }

    func testLatestPlacemarkID_ReturnsMostRecentPlacemarkOfDay() throws {
        var early = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 10))
        var late = try store.createLocal(lat: 49.80, lon: 9.95, collectedFrom: date(2026, 5, 19, 12))
        let current = try store.createLocal(lat: 49.81, lon: 9.96, collectedFrom: date(2026, 5, 19, 14))
        var otherDay = try store.createLocal(lat: 49.82, lon: 9.97, collectedFrom: date(2026, 5, 20, 14))
        early.placemark = "pm-early"
        late.placemark = "pm-late"
        otherDay.placemark = "pm-other-day"
        try store.update(early)
        try store.update(late)
        try store.update(otherDay)

        XCTAssertEqual(
            try store.latestPlacemarkID(collectingDay: current.collectingDay, excluding: current.id),
            "pm-late"
        )
    }

    func testLatestPlacemarkID_ExcludesGivenSampleAndSkipsRowsWithoutPlacemark() throws {
        var withPlacemark = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 10))
        var current = try store.createLocal(lat: 49.80, lon: 9.95, collectedFrom: date(2026, 5, 19, 12))
        _ = try store.createLocal(lat: 49.81, lon: 9.96, collectedFrom: date(2026, 5, 19, 14))
        withPlacemark.placemark = "pm-a"
        current.placemark = "pm-self"
        try store.update(withPlacemark)
        try store.update(current)

        XCTAssertEqual(
            try store.latestPlacemarkID(collectingDay: current.collectingDay, excluding: current.id),
            "pm-a"
        )
    }

    func testLatestPlacemarkID_ReturnsNilWhenNoneOnDay() throws {
        let current = try store.createLocal(lat: 49.79, lon: 9.94, collectedFrom: date(2026, 5, 19, 10))
        XCTAssertNil(try store.latestPlacemarkID(collectingDay: current.collectingDay, excluding: current.id))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.timeZone = berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: comps)!
    }

    private func makeRemoteSample(
        id: String,
        code: String,
        originalCode: String? = nil,
        clientUuid: String?
    ) -> Sample {
        let json = """
        {
          "id": "\(id)",
          "sample_id": "\(code)",
          "original_code": "\(originalCode ?? "")",
          "fieldtrip": "ft-1",
          "latitude": 49.79,
          "longitude": 9.94,
          "begin_date": "2026-05-19T14:00:00.000Z",
          "location_source": "location_service",
          "time_zone": "Europe/Berlin",
          "version": 1,
          "client_uuid": "\(clientUuid ?? "")",
          "client_updated_at": "2026-05-19T14:00:00.000Z"
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: Data(json.utf8))
    }
}
