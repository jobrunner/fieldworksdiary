@testable import Legulus
import XCTest

/// Kamerafotos werden sofort gespeichert (Datei und Zeile), nicht erst
/// beim Speichern der Probe, und lassen sich wieder löschen.
@MainActor
final class SampleEditorPhotoTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var photos: LocalPhotoStore!
    private var fieldtrips: LocalFieldtripStore!
    private var localities: LocalLocalityStore!
    private var mutations: PendingMutationsStore!
    private var sync: SyncRunner!
    private var sampleIDs: [String] = []
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        photos = LocalPhotoStore(database: database)
        fieldtrips = LocalFieldtripStore(database: database)
        localities = LocalLocalityStore(database: database)
        mutations = PendingMutationsStore(database: database)
        sync = SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "" },
            retryInterval: .seconds(3600)
        )
    }

    override func tearDownWithError() throws {
        for id in sampleIDs {
            PhotoStorage.deleteSampleDir(sampleID: id)
        }
        sampleIDs = []
        database = nil
        try super.tearDownWithError()
    }

    private func makeVM() throws -> SampleEditorViewModel {
        let sample = try samples.createLocal(lat: 49.79, lon: 9.94, notes: "")
        sampleIDs.append(sample.id)
        return SampleEditorViewModel(
            sampleID: sample.id, store: samples, photoStore: photos, fieldtripStore: fieldtrips,
            mutationsStore: mutations, sync: sync
        )
    }

    private func photoMutations() throws -> [PendingMutation] {
        try mutations.fetch(entityType: .samplePhoto)
    }

    func testAddCapturedPhoto_WritesFileAndRowImmediately() throws {
        let vm = try makeVM()
        let data = try PhotoStorageTests.jpeg(width: 40, height: 30)

        try vm.addCapturedPhoto(data)

        let rows = try photos.fetchBySample(vm.sampleID)
        XCTAssertEqual(rows.count, 1, "ohne saveEdits gespeichert")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.syncStatus, .pending)
        XCTAssertEqual(row.attempts, 0)
        XCTAssertNil(row.backendId)
        XCTAssertEqual(row.clientUuid, row.id)
        XCTAssertEqual(try PhotoStorage.readData(relativePath: row.localPath), data, "Datei bytegleich")
        XCTAssertEqual(vm.savedPhotos.map(\.id), [row.id])
        XCTAssertFalse(vm.hasUnsavedEdits, "ein gespeichertes Foto ist keine offene Änderung")
    }

    func testAddCapturedPhoto_SeriesKeepsOrder() throws {
        let vm = try makeVM()
        for width in [10, 20, 30] {
            try vm.addCapturedPhoto(PhotoStorageTests.jpeg(width: width, height: 10))
        }
        XCTAssertEqual(try photos.fetchBySample(vm.sampleID).count, 3)
        XCTAssertEqual(vm.savedPhotos.count, 3)
    }

    /// Die Datei eines Fotos, dessen Zeile nicht geschrieben werden
    /// konnte, darf nicht verwaist liegen bleiben.
    func testAddCapturedPhoto_InsertFailureRemovesFileAndThrows() throws {
        let vm = try makeVM()
        let data = try PhotoStorageTests.jpeg(width: 40, height: 30)
        try database.writer.write { db in try db.execute(sql: "DROP TABLE local_photos") }

        XCTAssertThrowsError(try vm.addCapturedPhoto(data))

        let dir = try XCTUnwrap(PhotoStorage.absoluteURL(forRelative: "photos/\(vm.sampleID)"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty, "verwaiste Datei: \(files)")
    }

    func testDeletePhoto_UnsyncedRemovesRowAndFileWithoutMutation() throws {
        let vm = try makeVM()
        try vm.addCapturedPhoto(PhotoStorageTests.jpeg(width: 40, height: 30))
        let row = try XCTUnwrap(photos.fetchBySample(vm.sampleID).first)

        vm.deletePhoto(id: row.id)

        XCTAssertTrue(try photos.fetchBySample(vm.sampleID).isEmpty)
        XCTAssertTrue(vm.savedPhotos.isEmpty)
        XCTAssertThrowsError(try PhotoStorage.readData(relativePath: row.localPath))
        XCTAssertTrue(try photoMutations().isEmpty, "noch nicht hochgeladen: nichts für den Server")
    }

    func testDeletePhoto_SyncedEnqueuesDeleteMutation() throws {
        let vm = try makeVM()
        try vm.addCapturedPhoto(PhotoStorageTests.jpeg(width: 40, height: 30))
        var row = try XCTUnwrap(photos.fetchBySample(vm.sampleID).first)
        row.backendId = "pbphoto00000001"
        row.syncStatus = .synced
        try photos.update(row)

        vm.deletePhoto(id: row.id)

        XCTAssertTrue(try photos.fetchBySample(vm.sampleID).isEmpty)
        let queued = try photoMutations()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.op, .delete)
        XCTAssertEqual(queued.first?.entityId, "pbphoto00000001")
    }

    /// Never confirmed, but the sample is on the server: an upload may
    /// have arrived without its answer. The delete leaves a tombstone
    /// with the client uuid, so the sync can look the record up.
    func testDeletePhoto_UnconfirmedOnPushedSampleLeavesTombstone() throws {
        let vm = try makeVM()
        var sample = try XCTUnwrap(samples.fetchById(vm.sampleID))
        sample.backendId = "pbsample0000001"
        sample.syncStatus = .synced
        try samples.update(sample)
        try vm.addCapturedPhoto(PhotoStorageTests.jpeg(width: 40, height: 30))
        let row = try XCTUnwrap(photos.fetchBySample(vm.sampleID).first)

        vm.deletePhoto(id: row.id)

        let queued = try photoMutations()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.op, .delete)
        XCTAssertNil(queued.first?.entityId)
        let payload = try XCTUnwrap(queued.first.map { try JSONDecoder().decode(PhotoDeletePayload.self, from: $0.payloadJson) })
        XCTAssertEqual(payload.clientUUID, row.clientUuid)
    }

    func testDeletePhoto_UnknownIDDoesNothing() throws {
        let vm = try makeVM()
        try vm.addCapturedPhoto(PhotoStorageTests.jpeg(width: 40, height: 30))
        vm.deletePhoto(id: "gibt-es-nicht")
        XCTAssertEqual(try photos.fetchBySample(vm.sampleID).count, 1)
        XCTAssertTrue(try photoMutations().isEmpty)
    }
}
