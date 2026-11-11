@testable import Fieldworksdiary
import FieldworksGeo
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

        XCTAssertEqual(list.calls.count, 3)
        XCTAssertTrue(list.calls.allSatisfy { $0.perPage == 200 && $0.updatedSince == nil })
        XCTAssertNil(list.calls.first?.after)
        XCTAssertNotNil(list.calls.last?.after)
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
        XCTAssertNil(list.calls.last?.after)
    }

    func testPull_FailureMidway_KeepsOldCursor() async throws {
        let list = MockList()
        list.items = (0 ..< 450).map { sample(index: $0) }
        list.failOnCall = 2
        let hydrator = makeHydrator(list)

        await hydrator.pull()

        XCTAssertNil(hydrator.currentCursor())
        list.failOnCall = nil
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

    func testPull_RowRewrittenBetweenPages_IsStillHydrated() async throws {
        let list = MockList()
        list.items = (0 ..< 4).map { sample(index: $0) }
        // After page 1 (rows 0, 1) row 0 is rewritten and moves to the end.
        list.beforeCall = { [unowned list] call in
            guard call == 2 else { return }
            list.items[0] = self.sample(index: 0, updatedIndex: 10)
        }
        let hydrator = makeHydrator(list, perPage: 2)

        await hydrator.pull()

        XCTAssertEqual(try store.count(), 4)
        for index in 0 ..< 4 {
            XCTAssertNotNil(try store.fetchByBackendID("backend-\(index)"), "row \(index) hydrated")
        }
    }

    func testPull_PlacemarkFetchFails_HoldsCursorThenRetries() async throws {
        let list = MockList()
        list.items = [sample(index: 1, placemark: "pmbackend00001")]
        let pm = FailablePlacemarks()
        pm.failing = true
        let placemarks = LocalPlacemarkStore(database: database)
        let features = LocalSampleFeatureStore(database: database)
        let hydrator = makeHydrator(list, placemarks: placemarks, features: features, pmClient: pm)

        await hydrator.pull()
        XCTAssertNil(hydrator.currentCursor(), "cursor must not pass a failed hydration")
        XCTAssertNil(try placemarks.fetchById("pmbackend00001"))

        pm.failing = false
        await hydrator.pull()
        XCTAssertNotNil(try placemarks.fetchById("pmbackend00001"))
        XCTAssertNotNil(hydrator.currentCursor())
        XCTAssertNil(list.calls.last?.updatedSince, "retry restarted from the unchanged cursor")
    }

    // MARK: - helpers

    private func makeHydrator(
        _ list: MockList,
        perPage: Int = 200,
        placemarks: LocalPlacemarkStore? = nil,
        features: LocalSampleFeatureStore? = nil,
        pmClient: PlacemarkSyncClient? = nil
    ) -> SamplesHydrator {
        SamplesHydrator(
            store: store,
            placemarks: placemarks,
            features: features,
            endpointProvider: { "http://test.invalid" },
            userIDProvider: { "u1" },
            defaults: defaults,
            perPage: perPage,
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pmClient ?? FailablePlacemarks() }
        )
    }

    /// Remote sample `index`; `updated` rises with the index.
    private func sample(
        index: Int, updatedIndex: Int? = nil, clientUuid: String? = nil, notes: String = "", placemark: String = ""
    ) -> Sample {
        let updated = Date(timeIntervalSince1970: 1_780_000_000 + Double(updatedIndex ?? index) * 60)
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
            "notes": notes,
            "placemark": placemark
        ]
        if let clientUuid { dict["client_uuid"] = clientUuid }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }
}

/// Placemark client whose fetch can be switched to fail.
private final class FailablePlacemarks: PlacemarkSyncClient, @unchecked Sendable {
    var failing = false

    func resolve(place _: Place, source _: Placemark.GeocodingSource) async throws -> Placemark {
        throw SampleClientError.http(status: 500, body: "unused")
    }

    func fetchMany(ids: [String]) async throws -> [Placemark] {
        if failing { throw SampleClientError.http(status: 503, body: "") }
        return ids.map(Self.placemark)
    }

    private static func placemark(id: String) -> Placemark {
        let dict: [String: Any] = [
            "id": id,
            "country": "DE",
            "country_iso": "DE",
            "geocoding_source": "backend_service",
            "dedup_hash": "hash-\(id)",
            "owner": "",
            "state": "Bayern",
            "state_native": "",
            "state_level": 4
        ]
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Placemark.self, from: data)
    }
}
