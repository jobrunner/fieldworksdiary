@testable import Fieldworksdiary
import XCTest

/// Tests für `(.sample, .update)`-Pfad im SyncRunner: PATCH-Replay
/// gegen das `SamplePushClient`-Mock, OCC-Versions-Bump (`current + 1`),
/// Re-Lesen der lokalen Row vor + nach `await` (kein Stale-Snapshot),
/// und Surface-Verhalten bei 409 / Netz-Fehler / fehlender backendId.
@MainActor
final class SyncRunnerSampleUpdateTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    func testUpdate_HappyPath_PatchesAndDequeues() async throws {
        let local = try seedSyncedSample(backendID: "backend-1", code: "260605/1", version: 3)
        var edited = local
        edited.notes = "updated note"
        try store.saveEdits(edited, mutationsStore: mutations)

        let mock = MockUpdateClient()
        mock.updateResponse = remoteSample(id: "backend-1", code: "260605/1", version: 4)
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        XCTAssertEqual(
            try mutations.fetch(entityType: .sample).filter { $0.op == .update }.count, 0,
            "successful PATCH dequeues the outbox row"
        )
        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.notes, "updated note")
        XCTAssertEqual(stored.version, 4)
    }

    func testUpdate_SendsVersionPlusOne() async throws {
        // OCC contract: backend's enforceVersion rejects incoming <=
        // current with 409. Client must send current + 1.
        _ = try seedSyncedSample(backendID: "backend-1", code: "260605/1", version: 5)
        let local = try XCTUnwrap(store.fetchAll().first)
        var edited = local
        edited.notes = "occ test"
        try store.saveEdits(edited, mutationsStore: mutations)

        let mock = MockUpdateClient()
        mock.updateResponse = remoteSample(id: "backend-1", code: "260605/1", version: 6)
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        let received = try XCTUnwrap(mock.lastUpdateInput)
        XCTAssertEqual(received.version, 6, "client must send current + 1, not current")
    }

    func testUpdate_ServerReassignsCode_KeepsLocalAsAudit() async throws {
        let local = try seedSyncedSample(backendID: "backend-1", code: "260605/1", version: 1)
        var edited = local
        edited.sampleID = "260605/9" // user changed the tube label
        try store.saveEdits(edited, mutationsStore: mutations)

        let mock = MockUpdateClient()
        mock.updateResponse = remoteSample(
            id: "backend-1",
            code: "260605/12",
            originalCode: "260605/9",
            version: 2
        )
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.backendCode, "260605/12")
        XCTAssertEqual(stored.originalCode, "260605/9")
    }

    func testUpdate_409_AdoptsServerVersionAndRetriesWithUserEdit() async throws {
        // The backend's enrichment bumped the version behind our back.
        let local = try seedSyncedSample(backendID: "backend-1", code: "260605/1", version: 1)
        var edited = local
        edited.notes = "user edit"
        try store.saveEdits(edited, mutationsStore: mutations)

        let mock = MockUpdateClient()
        mock.updateErrors = [SampleClientError.conflict(currentVersion: 7, body: "{}")]
        mock.fetchResponse = remoteSample(id: "backend-1", code: "260605/1", notes: "server", version: 7)
        mock.updateResponse = remoteSample(id: "backend-1", code: "260605/1", notes: "user edit", version: 8)
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        XCTAssertEqual(mock.updateInputs.map(\.version), [2, 8], "retry sends server version + 1")
        XCTAssertEqual(mock.updateInputs.last?.notes, "user edit", "the user's edit wins")
        XCTAssertEqual(try mutations.count(), 0)
        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.notes, "user edit")
        XCTAssertEqual(stored.version, 8)
    }

    func testUpdate_Repeated409_IsBoundedAndKeepsEdit() async throws {
        let local = try seedSyncedSample(backendID: "backend-1", code: "260605/1", version: 1)
        var edited = local
        edited.notes = "user edit"
        try store.saveEdits(edited, mutationsStore: mutations)

        let mock = MockUpdateClient()
        mock.alwaysConflict = true
        mock.fetchResponse = remoteSample(id: "backend-1", code: "260605/1", version: 7)
        let runner = makeRunner(mock: mock)
        for _ in 0 ..< 20 {
            await runUntilQuiescent(runner)
            try? await Task.sleep(for: .milliseconds(20))
            if try mutations.activeCount() == 0 { break }
        }
        // Further passes must not pick the row up again.
        await runUntilQuiescent(runner)
        try? await Task.sleep(for: .milliseconds(20))
        await runUntilQuiescent(runner)

        XCTAssertEqual(mock.updateInputs.count, SyncRunner.maxConflictAttempts * 2,
                       "two tries per pass, then it stops")
        XCTAssertEqual(try mutations.activeCount(), 0, "no endless retry, no create re-adoption")
        let parked = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(parked.count, 1, "the edit's mutation is parked for „Erneut senden“, not dropped")
        XCTAssertTrue(parked.first?.isParked ?? false)
        XCTAssertEqual(parked.first?.op, .update)
        let stored = try XCTUnwrap(store.fetchById(local.id))
        XCTAssertEqual(stored.syncStatus, .failed)
        XCTAssertNotNil(stored.syncError)
        XCTAssertEqual(stored.notes, "user edit", "edit kept locally")
    }

    func testUpdate_MissingLocalRow_DequeuesSilently() async throws {
        // Mutation with a nonexistent local id — sample row vanished
        // (reset, account switch). The runner drops it.
        _ = try mutations.enqueue(
            entityType: .sample,
            entityId: "ghost-local-id",
            op: .update,
            payload: Data()
        )

        let mock = MockUpdateClient()
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        XCTAssertEqual(try mutations.count(), 0, "orphan update is dropped")
    }

    func testUpdate_NoBackendIdYet_LeavesMutationQueued() async throws {
        // Sample exists locally but hasn't been pushed yet (create
        // still in flight). The update mutation must NOT be dropped —
        // it'll fire on the next pass once backendId arrives.
        //
        // We flip syncStatus to .syncing so `reconcileLegacyPending`
        // doesn't auto-enqueue a .create on top of our test mutation
        // (it would, because createLocal seeds .pending and the
        // runner adopts those into the outbox at the start of every
        // pass).
        var sample = try store.createLocal(lat: 49.79, lon: 9.94, notes: "x")
        sample.backendId = nil
        sample.syncStatus = .syncing
        try store.update(sample)
        _ = try mutations.enqueue(
            entityType: .sample,
            entityId: sample.id,
            op: .update,
            payload: Data()
        )

        let mock = MockUpdateClient()
        let runner = makeRunner(mock: mock)
        await runUntilQuiescent(runner)

        XCTAssertEqual(
            try mutations.fetch(entityType: .sample).filter { $0.op == .update }.count, 1,
            "no backend id yet → keep the update queued; do not dequeue"
        )
    }

    // MARK: - helpers

    @discardableResult
    private func seedSyncedSample(
        backendID: String,
        code: String,
        version: Int = 1
    ) throws -> LocalSample {
        var sample = try store.createLocal(
            lat: 49.79, lon: 9.94,
            collectedFrom: date(2026, 6, 5, 14)
        )
        sample.sampleID = code
        sample.backendId = backendID
        sample.syncStatus = .synced
        sample.version = version
        // Resolved place data: plain edits go straight to the PATCH
        // (weak states fetch the server row first, see SyncRunnerOrtusTests).
        sample.locationStatus = .backendService
        try store.update(sample)
        // swiftlint:disable:next force_unwrapping
        return try store.fetchById(sample.id)!
    }

    private func makeRunner(mock: MockUpdateClient) -> SyncRunner {
        SyncRunner(
            store: store,
            mutationsStore: mutations,
            endpointProvider: { "http://test.invalid" },
            authProvider: { nil },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(1),
            clientFactory: { _, _ in mock }
        )
    }

    private func runUntilQuiescent(_ runner: SyncRunner) async {
        runner.kick()
        for _ in 0 ..< 200 {
            try? await Task.sleep(for: .milliseconds(10))
            if runner.isIdleForTest { return }
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
        notes: String? = nil,
        version: Int = 2
    ) -> Sample {
        var dict: [String: Any] = [
            "id": id,
            "sample_id": code,
            "fieldtrip": "",
            "latitude": 49.79,
            "longitude": 9.94,
            "begin_date": "2026-06-05T14:00:00.000Z",
            "client_updated_at": "2026-06-05T14:00:00.000Z",
            "location_source": "location_service",
            "timezone": "Europe/Berlin",
            "version": version
        ]
        if let originalCode { dict["original_code"] = originalCode }
        if let notes { dict["notes"] = notes }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }
}

private final class MockUpdateClient: SamplePushClient, @unchecked Sendable {
    var updateResponse: Sample?
    var updateError: Error?
    /// Errors for the first calls, in order; afterwards `updateResponse`.
    var updateErrors: [Error] = []
    var alwaysConflict = false
    var fetchResponse: Sample?
    var createResponse: Sample?
    /// Every input the SyncRunner sent, in order.
    var updateInputs: [SampleUpdateInput] = []
    var lastUpdateInput: SampleUpdateInput? { updateInputs.last }

    func createSample(_: SampleCreateInput) async throws -> Sample {
        guard let createResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return createResponse
    }

    func updateSample(id _: String, input: SampleUpdateInput) async throws -> Sample {
        updateInputs.append(input)
        if alwaysConflict { throw SampleClientError.conflict(currentVersion: 7, body: "{}") }
        if !updateErrors.isEmpty { throw updateErrors.removeFirst() }
        if let updateError { throw updateError }
        guard let updateResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return updateResponse
    }

    func fetchSample(id _: String) async throws -> Sample {
        guard let response = fetchResponse ?? updateResponse else {
            throw SampleClientError.http(status: 404, body: "")
        }
        return response
    }
}
