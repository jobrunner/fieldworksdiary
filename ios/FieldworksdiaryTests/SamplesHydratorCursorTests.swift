@testable import Fieldworksdiary
import XCTest

/// Task 21: the samples hydrator pages through all samples on the first
/// run and only fetches `updated >= cursor` afterwards.
@MainActor
final class SamplesHydratorCursorTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1")
        mutations = PendingMutationsStore(database: database)
        suiteName = "SamplesHydratorCursorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    func testPull_FirstRun_PagesThroughAll() async throws {
        let list = MockList()
        list.items = (0 ..< 450).map { sample(index: $0) }
        let hydrator = makeHydrator(list)

        await hydrator.pull()

        XCTAssertEqual(list.calls.map(\.page), [1, 2, 3])
        XCTAssertTrue(list.calls.allSatisfy { $0.perPage == 200 && $0.updatedSince == nil })
        XCTAssertEqual(try store.count(), 450)
    }

    func testPull_SecondRun_OnlyUpdatedSinceCursor() async throws {
        let list = MockList()
        list.items = (0 ..< 5).map { sample(index: $0) }
        let hydrator = makeHydrator(list)

        await hydrator.pull()
        await hydrator.pull()

        let expected = try XCTUnwrap(list.items.compactMap(\.updated).max())
        XCTAssertEqual(list.calls.count, 2)
        XCTAssertEqual(list.calls.last?.updatedSince, expected)
        XCTAssertEqual(list.calls.last?.page, 1)
    }

    func testPull_FailureMidway_KeepsOldCursor() async throws {
        let list = MockList()
        list.items = (0 ..< 450).map { sample(index: $0) }
        list.failOnPage = 2
        let hydrator = makeHydrator(list)

        await hydrator.pull()

        XCTAssertNil(hydrator.currentCursor())
        list.failOnPage = nil
        await hydrator.pull()
        XCTAssertEqual(list.calls.last?.updatedSince, nil, "retry starts from the old (nil) cursor")
        XCTAssertNotNil(hydrator.currentCursor())
    }

    func testReset_ClearsCursor() async throws {
        let list = MockList()
        list.items = (0 ..< 5).map { sample(index: $0) }
        let hydrator = makeHydrator(list)
        await hydrator.pull()
        XCTAssertNotNil(hydrator.currentCursor())

        try store.reset()
        hydrator.resetCursor()
        await hydrator.pull()

        XCTAssertNil(list.calls.last?.updatedSince, "full scan again after reset")
        XCTAssertEqual(try store.count(), 5)
    }

    func testPull_SkipsRowsWithPendingLocalChanges() async throws {
        var local = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: Date(timeIntervalSince1970: 1_780_000_000))
        local.backendId = "backend-1"
        local.syncStatus = .synced
        local.version = 2
        try store.update(local)
        local.notes = "local edit"
        try store.saveEdits(local, mutationsStore: mutations)

        let list = MockList()
        list.items = [sample(index: 1, clientUuid: local.id, notes: "remote")]
        let hydrator = makeHydrator(list)

        await hydrator.pull()

        XCTAssertEqual(try store.fetchById(local.id)?.notes, "local edit")
    }

    // MARK: - helpers

    private func makeHydrator(_ list: MockList) -> SamplesHydrator {
        SamplesHydrator(
            store: store,
            endpointProvider: { "http://test.invalid" },
            userIDProvider: { "u1" },
            defaults: defaults,
            clientFactory: { _, _ in list }
        )
    }

    /// Remote sample `index`; `updated` rises with the index.
    private func sample(index: Int, clientUuid: String? = nil, notes: String = "") -> Sample {
        let updated = Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 60)
        var dict: [String: Any] = [
            "id": "backend-\(index)",
            "sample_id": "S\(index)",
            "fieldtrip": "ft-1",
            "locality": "",
            "latitude": 49.68,
            "longitude": 10.04,
            "begin_date": "2026-05-19T12:00:00.000Z",
            "client_updated_at": "2026-05-19T12:00:00.000Z",
            "updated": SampleClient.pocketBaseDate(updated),
            "location_source": "location_service",
            "timezone": "Europe/Berlin",
            "version": 3,
            "notes": notes
        ]
        if let clientUuid { dict["client_uuid"] = clientUuid }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }
}
