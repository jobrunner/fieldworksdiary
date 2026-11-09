@testable import Fieldworksdiary
import XCTest

/// R8d: the SyncRunner's `.locality/.create` dispatch. A client-
/// created locality carries a UUID id; pushing it must swap that for
/// the backend id and re-point any samples that referenced the UUID.
@MainActor
final class SyncRunnerLocalityTests: XCTestCase {
    private var database: Database!
    private var localities: LocalLocalityStore!
    private var samples: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        localities = LocalLocalityStore(database: database)
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        localities = nil
        samples = nil
        mutations = nil
        try super.tearDownWithError()
    }

    func testLocalityCreate_ReconcilesUUIDToBackendIDAndRepointsSamples() async throws {
        // A locally-created locality (UUID id) plus a sample on it.
        let local = try localities.createLocal(latitude: 49.79, longitude: 9.94)
        try seedSample(id: "s1", locality: local.id)
        _ = try mutations.enqueue(
            entityType: .locality, entityId: local.id, op: .create, payload: Data()
        )

        let mock = MockLocalityClient()
        mock.createResponse = remoteLocality(id: "backend-loc-1", name: local.name)
        let runner = makeRunner(mock: mock)

        await runUntilOutboxEmpty(runner)

        // The mutation is gone, the UUID row is gone, the backend row
        // exists, and the sample now points at the backend id.
        XCTAssertEqual(try mutations.count(), 0)
        XCTAssertNil(try localities.fetchById(local.id))
        XCTAssertNotNil(try localities.fetchById("backend-loc-1"))
        let movedSample = try XCTUnwrap(samples.fetchById("s1"))
        XCTAssertEqual(movedSample.locality, "backend-loc-1")
        // The push body carried the Spec-aligned coordinate.
        XCTAssertEqual(mock.lastInput?.latitude, 49.79)
        XCTAssertEqual(mock.lastInput?.locationSource, .locationService)
    }

    func testLocalityCreate_FailureKeepsMutationForRetry() async throws {
        let local = try localities.createLocal(latitude: 49.79, longitude: 9.94)
        _ = try mutations.enqueue(
            entityType: .locality, entityId: local.id, op: .create, payload: Data()
        )
        let mock = MockLocalityClient()
        mock.createError = SampleClientError.http(status: 500, body: "boom")
        let runner = makeRunner(mock: mock)

        runner.kick()
        // Give the pass a moment; the mutation must survive.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(try mutations.count(), 1)
        XCTAssertNotNil(try localities.fetchById(local.id), "UUID row stays until success")
    }

    // MARK: - helpers

    private func makeRunner(mock: MockLocalityClient) -> SyncRunner {
        SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "http://test.invalid" },
            authProvider: { nil },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(1),
            localityClientFactory: { _, _ in mock }
        )
    }

    private func runUntilOutboxEmpty(_ runner: SyncRunner) async {
        runner.kick()
        for _ in 0 ..< 200 {
            try? await Task.sleep(for: .milliseconds(10))
            if (try? mutations.count()) == 0, runner.isIdleForTest {
                return
            }
        }
    }

    private func seedSample(id: String, locality: String) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                           INSERT INTO local_samples (
                               id, sample_id, user_id, collecting_day,
                               latitude, longitude, begin_date,
                               is_all_day, time_zone, version,
                               notes, marked, locality, location_source,
                               sync_status, created_at, updated_at
                           ) VALUES (?, ?, 'u1', '2026-05-19',
                                     49.79, 9.94, ?,
                                     0, 'Europe/Berlin', 1,
                                     '', 0, ?, 1,
                                     'synced', ?, ?)
                           """,
                           arguments: [id, "260519/1", Date(), locality, Date(), Date()])
        }
    }

    private func remoteLocality(id: String, name: String) -> Locality {
        let dict: [String: Any] = [
            "id": id,
            "name": name,
            "latitude": 49.79,
            "longitude": 9.94,
            "radius_m": 50,
            "location_source": "location_service",
            "version": 1
        ]
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Locality.self, from: data)
    }
}

private final class MockLocalityClient: LocalityPushClient, @unchecked Sendable {
    var createResponse: Locality?
    var createError: Error?
    var lastInput: LocalityInput?

    func create(_ input: LocalityInput) async throws -> Locality {
        lastInput = input
        if let createError { throw createError }
        // swiftlint:disable:next force_unwrapping
        return createResponse!
    }
}
