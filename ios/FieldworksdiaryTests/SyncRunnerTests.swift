@testable import Fieldworksdiary
import XCTest

/// Tests für die Sync-Pipeline. Die HTTP-Schicht ist via
/// `SamplePushClient`-Protokoll abstrahiert; ein `MockClient`
/// liefert vordefinierte Antworten ohne Netz.
@MainActor
final class SyncRunnerTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "user-a", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy Path

    func testPush_HappyPath_MarksSampleAsSynced() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        let mock = MockClient()
        mock.createResponse = remoteSample(
            id: "backend-1",
            code: local.sampleID,
            fieldtrip: "ft-1"
        )

        let onSyncedExpectation = expectation(description: "onSampleSynced fired")
        var notifiedFieldtripID: String?
        let runner = makeRunner(mock: mock) { ftID in
            notifiedFieldtripID = ftID
            onSyncedExpectation.fulfill()
        }

        await runUntilQuiescent(runner)
        await fulfillment(of: [onSyncedExpectation], timeout: 2.0)

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.backendId, "backend-1")
        XCTAssertEqual(stored.fieldtrip, "ft-1")
        XCTAssertEqual(notifiedFieldtripID, "ft-1")
    }

    // MARK: - Server-Code-Reassignment

    func testPush_ServerReassignsCode_LocalCodeAsAudit() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        XCTAssertEqual(local.sampleID, "260519/1")

        let mock = MockClient()
        mock.createResponse = remoteSample(
            id: "backend-1",
            code: "260519/7",
            originalCode: "260519/1",
            fieldtrip: "ft-1"
        )
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.sampleID, "260519/1", "Lokaler Code (= auf Röhrchen) bleibt")
        XCTAssertEqual(stored.backendCode, "260519/7", "Server-Code separat festgehalten")
        XCTAssertEqual(stored.originalCode, "260519/1", "originalCode dokumentiert den Konflikt")
        XCTAssertEqual(stored.syncStatus, .synced)
    }

    func testPush_ServerHonorsCode_DoesNotSetBackendCode() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        let mock = MockClient()
        mock.createResponse = remoteSample(
            id: "backend-1",
            code: local.sampleID,
            fieldtrip: "ft-1"
        )
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.sampleID, local.sampleID)
        XCTAssertNil(stored.backendCode, "Bei Honorierung kein backendCode")
    }

    // MARK: - Failure

    func testPush_NetworkFailure_MarksSampleAsFailed() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        let mock = MockClient()
        mock.createError = SampleClientError.http(status: 500, body: "boom")
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.syncStatus, .failed)
        XCTAssertNil(stored.backendId)
        XCTAssertNotNil(stored.syncError)
        XCTAssertTrue(stored.syncError?.contains("500") ?? false,
                      "syncError zitiert HTTP-Status: \(stored.syncError ?? "nil")")
    }

    // MARK: - Enrichment-Poll

    func testPollEnrichment_AppliesFlatMTBWhenServerEnriched() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 5, 19, 14)
        )
        let mock = MockClient()
        mock.createResponse = remoteSample(id: "backend-1", code: local.sampleID, fieldtrip: "ft-1")
        mock.fetchResponse = remoteSample(
            id: "backend-1",
            code: local.sampleID,
            fieldtrip: "ft-1",
            mtbSheet: "6225",
            locationStatus: "backend_service",
            version: 2
        )
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)
        // pollEnrichment ist async, läuft nach onSampleSynced — etwas
        // Slack geben.
        try await Task.sleep(for: .milliseconds(200))

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.mtbSheetNumber, "6225")
        XCTAssertEqual(stored.mtbSheetName, "Test")
        XCTAssertEqual(stored.mtbQuadrant, 1)
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.version, 2, "enrichment bumps version; local follows so the next PATCH doesn't 409")
    }

    func testPush_SendsElevationAndRealLocationSource() async throws {
        let local = try store.createLocal(
            lat: 49.79, lon: 9.94, elevation: 312,
            collectedFrom: date(2026, 5, 19, 14),
            locationSource: .user
        )
        let mock = MockClient()
        mock.createResponse = remoteSample(id: "backend-1", code: local.sampleID, fieldtrip: "ft-1")
        await runUntilQuiescent(makeRunner(mock: mock))

        let sent = try XCTUnwrap(mock.lastCreateInput)
        XCTAssertEqual(sent.location.elevation, 312)
        XCTAssertEqual(sent.location.elevationSource, .locationService)
        XCTAssertEqual(sent.location.locationSource, .user, "manual coordinate goes out as `user`")
        XCTAssertEqual(sent.location.locationStatus, .pending)
        let body = sent.location.wireBody
        XCTAssertEqual(body["elevation"] as? Double, 312)
        XCTAssertNil(body["altitude"], "samples use `elevation` since Phase O")
        XCTAssertEqual(body["elevation_source"] as? String, "location_service")
        XCTAssertEqual(body["location_source"] as? String, "user")
        XCTAssertEqual(body["location_status"] as? String, "pending")
    }

    func testDecode_ServerSampleWithoutEnrichment_HasNoGeo() throws {
        let sample = remoteSample(id: "b", code: "260519/1", fieldtrip: "ft")
        XCTAssertNil(sample.geo, "PocketBase zeros must not count as enrichment")
        XCTAssertNil(sample.elevation)
        XCTAssertNil(sample.locationStatus)
    }

    // MARK: - helpers

    private func makeRunner(
        mock: MockClient,
        onSampleSynced: @escaping (String) -> Void = { _ in }
    ) -> SyncRunner {
        SyncRunner(
            store: store,
            mutationsStore: mutations,
            endpointProvider: { "http://test.invalid" },
            authProvider: { nil },
            retryInterval: .seconds(3600), // retry-Loop praktisch aus
            enrichmentPollInterval: .milliseconds(1),
            clientFactory: { _, _ in mock },
            onSampleSynced: onSampleSynced
        )
    }

    /// `kick()` startet einen Task. Wir warten, bis er fertig ist.
    private func runUntilQuiescent(_ runner: SyncRunner) async {
        runner.kick()
        // SyncRunner.passTask wird beim Abschluss auf nil gesetzt. Wir
        // pollen über `inFlight` UND einen kurzen Yield-Loop. inFlight
        // ist nur während des HTTP-Calls > 0; danach läuft pollEnrichment
        // noch im Hintergrund. Wir warten auf passTask == nil über die
        // public-Lifecycle: kick() ist no-op solange passTask läuft.
        for _ in 0 ..< 200 {
            try? await Task.sleep(for: .milliseconds(10))
            if runner.isIdleForTest {
                return
            }
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.timeZone = berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: c)!
    }

    private func remoteSample(
        id: String,
        code: String,
        originalCode: String? = nil,
        fieldtrip: String,
        locality: String? = nil,
        mtbSheet: String? = nil,
        locationStatus: String? = nil,
        version: Int = 1
    ) -> Sample {
        var dict: [String: Any] = [
            "id": id,
            "sample_id": code,
            "fieldtrip": fieldtrip,
            "latitude": 49.79,
            "longitude": 9.94,
            "begin_date": "2026-05-19T14:00:00.000Z",
            "client_updated_at": "2026-05-19T14:00:00.000Z",
            "location_source": "location_service",
            "timezone": "Europe/Berlin",
            "version": version,
            // PocketBase returns unset columns as zero values.
            "elevation": 0,
            "elevation_source": "",
            "location_status": locationStatus ?? "",
            "placemark": "",
            "mtb_sheet_number": mtbSheet ?? "",
            "mtb_sheet_name": mtbSheet == nil ? "" : "Test",
            "mtb_quadrant": mtbSheet == nil ? 0 : 1,
            "slope_deg": 0,
            "aspect_deg": 0,
            "terrain_flat": false,
            "bearing_inside": false
        ]
        if let originalCode { dict["original_code"] = originalCode }
        if let locality { dict["locality"] = locality }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }
}

// MARK: - Mock

/// Mock-Implementation des Push-Protokolls.
private final class MockClient: SamplePushClient, @unchecked Sendable {
    var createResponse: Sample?
    var fetchResponse: Sample?
    var createError: Error?
    var updateResponse: Sample?
    var updateError: Error?
    var lastCreateInput: SampleCreateInput?

    func createSample(_ input: SampleCreateInput) async throws -> Sample {
        lastCreateInput = input
        if let createError { throw createError }
        // swiftlint:disable:next force_unwrapping
        return createResponse!
    }

    func updateSample(id _: String, input _: SampleUpdateInput) async throws -> Sample {
        if let updateError { throw updateError }
        // swiftlint:disable:next force_unwrapping
        return updateResponse!
    }

    func fetchSample(id _: String) async throws -> Sample {
        // swiftlint:disable:next force_unwrapping
        return fetchResponse ?? createResponse!
    }
}

// Test-Hook: erlaubt zu prüfen, ob ein laufender Pass abgeschlossen
// ist, ohne private Internals offenzulegen.
@MainActor
extension SyncRunner {
    var isIdleForTest: Bool {
        inFlight == 0
    }
}
