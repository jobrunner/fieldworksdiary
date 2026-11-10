@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// `LocalSampleStore.deleteSample`: lokal alles weg; ungepushte Samples
/// erzeugen keine Mutation, gepushte eine `.sample/.delete` mit Backend-ID.
@MainActor
final class LocalSampleStoreDeleteTests: XCTestCase {
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

    private func addDependents(to sample: LocalSample) throws {
        try LocalPhotoStore(database: database).insert(LocalPhoto(
            id: "photo-1", sampleId: sample.id, localPath: "photos/\(sample.id)/photo-1.jpg",
            backendId: nil, syncStatus: .pending, syncError: nil, clientUuid: "photo-1",
            clientUpdatedAt: Date(), createdAt: Date()
        ))
        try LocalSampleFeatureStore(database: database).replace(sampleID: sample.id, features: [
            OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: "1",
                         propertiesJSON: "{}", licenseJSON: nil)
        ])
    }

    func testDelete_LocalOnly_RemovesRowDependentsAndQueuedCreate() throws {
        let sample = try store.createLocal(lat: 49.79, lon: 9.94)
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .create, payload: Data())
        try addDependents(to: sample)

        try store.deleteSample(id: sample.id, mutationsStore: mutations)

        XCTAssertNil(try store.fetchById(sample.id))
        XCTAssertEqual(try LocalPhotoStore(database: database).fetchBySample(sample.id).count, 0)
        XCTAssertEqual(try LocalSampleFeatureStore(database: database).count(sampleID: sample.id), 0)
        XCTAssertEqual(try mutations.count(), 0, "no create, no delete for a never-pushed sample")
    }

    func testDelete_Pushed_QueuesDeleteWithBackendIdAndDropsOtherMutations() throws {
        var sample = try store.createLocal(lat: 49.79, lon: 9.94)
        sample.backendId = "backend-1"
        try store.update(sample)
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update, payload: Data())
        try addDependents(to: sample)

        try store.deleteSample(id: sample.id, mutationsStore: mutations)

        XCTAssertNil(try store.fetchById(sample.id))
        XCTAssertEqual(try LocalPhotoStore(database: database).fetchBySample(sample.id).count, 0)
        XCTAssertEqual(try LocalSampleFeatureStore(database: database).count(sampleID: sample.id), 0)
        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.op, .delete)
        XCTAssertEqual(queued.first?.entityId, "backend-1")
    }

    func testDelete_UnknownId_IsNoOp() throws {
        try store.deleteSample(id: "nope", mutationsStore: mutations)
        XCTAssertEqual(try mutations.count(), 0)
    }

    func testUpsert_SkipsSampleWithQueuedDelete() throws {
        _ = try mutations.enqueue(entityType: .sample, entityId: "backend-1", op: .delete, payload: Data())
        let json = """
        {"id":"backend-1","sample_id":"260519/1","fieldtrip":"ft","latitude":49.79,"longitude":9.94,
         "begin_date":"2026-05-19T14:00:00.000Z","client_updated_at":"2026-05-19T14:00:00.000Z",
         "location_source":"location_service","timezone":"Europe/Berlin","version":1}
        """
        let remote = try JSONDecoder.fieldworks.decode(Sample.self, from: Data(json.utf8))

        try store.upsert([remote])

        XCTAssertEqual(try store.count(), 0, "deleted-locally sample must not be resurrected by hydration")
    }
}
