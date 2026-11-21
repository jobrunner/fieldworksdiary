@testable import Legulus
import XCTest

/// Fotos werden in jedem Durchlauf hochgeladen, unabhängig von einer
/// Änderung an der Probe; „nur im WLAN“ hält sie zurück; Löschen läuft
/// über die Outbox.
@MainActor
final class SyncRunnerPhotoTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var photos: LocalPhotoStore!
    private var mutations: PendingMutationsStore!
    private var client: FakePhotoClient!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var uploadAllowed = true
    private var wifiOnly = false
    private var account: String? = "user-a"
    private var lastSampleID: String?
    private var sampleIDs: [String] = []
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "user-a", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        photos = LocalPhotoStore(database: database)
        mutations = PendingMutationsStore(database: database)
        client = FakePhotoClient()
        uploadAllowed = true
    }

    override func tearDownWithError() throws {
        for id in sampleIDs {
            PhotoStorage.deleteSampleDir(sampleID: id)
        }
        sampleIDs = []
        database = nil
        try super.tearDownWithError()
    }

    private func makeRunner() -> SyncRunner {
        SyncRunner(
            store: store,
            mutationsStore: mutations,
            photoStore: photos,
            endpointProvider: { "http://test.invalid" },
            authProvider: { nil },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(1),
            clientFactory: { _, _ in NoSampleClient() },
            photoClientFactory: { [client] _, _ in client! }, // swiftlint:disable:this force_unwrapping
            photoUploadAllowed: { [unowned self] in self.uploadAllowed },
            photoWiFiOnly: { [unowned self] in self.wifiOnly },
            accountProvider: { [unowned self] in self.account },
            now: { [unowned self] in self.now }
        )
    }

    private func run(_ runner: SyncRunner) async {
        runner.kick()
        for _ in 0 ..< 300 {
            try? await Task.sleep(for: .milliseconds(10))
            if runner.isIdleForTest { return }
        }
        XCTFail("sync pass did not finish")
    }

    /// A sample that is already on the server (or not), with one photo
    /// on disk and no pending mutation of its own.
    private func seed(pushed: Bool, sameSample: Bool = false) throws -> LocalPhoto {
        var sample: LocalSample
        if sameSample, let lastSampleID, let existing = try store.fetchById(lastSampleID) {
            sample = existing
        } else {
            sample = try store.createLocal(lat: 49.79, lon: 9.94, notes: "")
            sampleIDs.append(sample.id)
            if pushed {
                sample.backendId = "pbsample0000001"
                sample.syncStatus = .synced
                try store.update(sample)
            }
        }
        lastSampleID = sample.id
        for mutation in try mutations.fetchAllOrdered() {
            try mutations.dequeue(mutation.id)
        }
        let id = UUID().uuidString
        let path = try PhotoStorage.write(data: PhotoStorageTests.jpeg(width: 20, height: 20), sampleID: sample.id, photoID: id)
        let photo = LocalPhoto(
            id: id, sampleId: sample.id, localPath: path, backendId: nil, syncStatus: .pending,
            syncError: nil, clientUuid: id, clientUpdatedAt: now, createdAt: now
        )
        try photos.insert(photo)
        return photo
    }

    private func row(_ photo: LocalPhoto) throws -> LocalPhoto? {
        try photos.fetchBySample(photo.sampleId).first { $0.id == photo.id }
    }

    func testUploadsPhotoWithoutPendingSampleMutation() async throws {
        let photo = try seed(pushed: true)
        await run(makeRunner())
        XCTAssertEqual(client.uploads.map(\.clientUUID), [photo.clientUuid])
        XCTAssertEqual(client.uploads.first?.sampleBackendID, "pbsample0000001")
        let stored = try XCTUnwrap(row(photo))
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.backendId, "pbphoto-1")
    }

    func testUploadSendsTheFileUnchanged() async throws {
        let photo = try seed(pushed: true)
        let original = try PhotoStorage.readData(relativePath: photo.localPath)
        await run(makeRunner())
        XCTAssertEqual(client.uploads.first?.bytes, original)
    }

    func testSkipsPhotoOfSampleThatIsNotOnTheServerYet() async throws {
        let photo = try seed(pushed: false)
        await run(makeRunner())
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(try row(photo)?.syncStatus, .pending)
    }

    func testWiFiOnly_HoldsPhotosBackUntilAllowed() async throws {
        let photo = try seed(pushed: true)
        uploadAllowed = false
        let runner = makeRunner()
        await run(runner)
        XCTAssertTrue(client.uploads.isEmpty, "nur WLAN, kein WLAN")
        XCTAssertEqual(try row(photo)?.attempts, 0, "Warten ist kein Fehlversuch")

        uploadAllowed = true
        await run(runner)
        XCTAssertEqual(client.uploads.count, 1)
    }

    /// Wi-Fi drops (or the setting is switched on) in the middle of a
    /// batch: the remaining photos wait.
    func testPermissionIsCheckedBeforeEveryPhoto() async throws {
        _ = try seed(pushed: true)
        _ = try seed(pushed: true, sameSample: true)
        client.duringUpload = { [unowned self] in self.uploadAllowed = false }
        await run(makeRunner())
        XCTAssertEqual(client.uploads.count, 1, "nach dem ersten Foto war der Upload nicht mehr erlaubt")
    }

    /// With „nur im WLAN“ the request itself must not fall back to
    /// cellular when the network changes between check and transfer.
    func testWiFiOnly_RequestForbidsCellular() async throws {
        _ = try seed(pushed: true)
        wifiOnly = true
        await run(makeRunner())
        XCTAssertEqual(client.cellularAllowed, [false])
        _ = try seed(pushed: true, sameSample: true)
        wifiOnly = false
        await run(makeRunner())
        XCTAssertEqual(client.cellularAllowed, [false, true])
    }

    func testTransientFailure_RetriesOnlyAfterTheDelay() async throws {
        let photo = try seed(pushed: true)
        client.nextError = SampleClientError.http(status: 500, body: "")
        let runner = makeRunner()
        await run(runner)
        var stored = try XCTUnwrap(row(photo))
        XCTAssertEqual(stored.syncStatus, .failed)
        XCTAssertEqual(stored.attempts, 1)
        XCTAssertEqual(stored.lastAttemptAt, now)
        XCTAssertEqual(client.attempts, 1)

        await run(runner)
        XCTAssertEqual(client.attempts, 1, "vor Ablauf der Wartezeit kein neuer Versuch")

        now = now.addingTimeInterval(61)
        await run(runner)
        XCTAssertEqual(client.attempts, 2)
        stored = try XCTUnwrap(row(photo))
        XCTAssertEqual(stored.syncStatus, .synced)
    }

    func testPermanentFailure_IsNotRetriedInThisRun() async throws {
        let photo = try seed(pushed: true)
        client.nextError = SampleClientError.http(status: 413, body: "")
        let runner = makeRunner()
        await run(runner)
        XCTAssertEqual(client.attempts, 1)
        now = now.addingTimeInterval(24 * 3600)
        await run(runner)
        XCTAssertEqual(client.attempts, 1, "413 wird in diesem App-Lauf nicht wiederholt")
        XCTAssertEqual(try row(photo)?.syncStatus, .failed)
    }

    /// The user deletes the photo while its upload is on the wire: the
    /// record the server just created must be removed again.
    func testDeletedDuringUpload_ServerCopyIsRemoved() async throws {
        let photo = try seed(pushed: true)
        client.duringUpload = { [photos] in
            try? photos?.delete(id: photo.id)
        }
        let runner = makeRunner()
        await run(runner)
        await run(runner)
        XCTAssertEqual(client.deleted, ["pbphoto-1"])
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
        XCTAssertNil(try row(photo))
    }

    func testDeleteMutation_CallsClientAndDequeues() async throws {
        _ = try mutations.enqueue(entityType: .samplePhoto, entityId: "pbphoto-9", op: .delete, payload: Data("{}".utf8))
        await run(makeRunner())
        XCTAssertEqual(client.deleted, ["pbphoto-9"])
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
    }

    /// Tombstone of a photo deleted before its upload was confirmed:
    /// the record is looked up by client uuid and removed.
    func testTombstone_LooksTheRecordUpAndDeletesIt() async throws {
        let payload = try JSONEncoder().encode(PhotoDeletePayload(clientUUID: "uuid-lost"))
        _ = try mutations.enqueue(entityType: .samplePhoto, entityId: nil, op: .delete, payload: payload)
        now = Date()
        client.known["uuid-lost"] = "pbphoto-lost"
        await run(makeRunner())
        XCTAssertEqual(client.lookups, ["uuid-lost"])
        XCTAssertEqual(client.deleted, ["pbphoto-lost"])
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
    }

    /// Nothing found is not yet "nothing arrived": a POST the client
    /// gave up on may still be processed. The tombstone stays for a
    /// grace period and is looked up again; only then is it dropped.
    func testTombstone_NothingOnTheServerIsKeptForTheGracePeriod() async throws {
        let payload = try JSONEncoder().encode(PhotoDeletePayload(clientUUID: "uuid-never"))
        let queued = try mutations.enqueue(entityType: .samplePhoto, entityId: nil, op: .delete, payload: payload)
        now = queued.createdAt.addingTimeInterval(60)
        let runner = makeRunner()
        await run(runner)
        XCTAssertEqual(client.lookups, ["uuid-never"])
        XCTAssertEqual(try mutations.fetch(entityType: .samplePhoto).count, 1, "noch in der Wartefrist")

        // The delayed POST arrives in the meantime.
        client.known["uuid-never"] = "pbphoto-late"
        await run(runner)
        XCTAssertEqual(client.deleted, ["pbphoto-late"])
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
    }

    func testTombstone_NothingOnTheServerAfterTheGracePeriodIsDone() async throws {
        let payload = try JSONEncoder().encode(PhotoDeletePayload(clientUUID: "uuid-never"))
        let queued = try mutations.enqueue(entityType: .samplePhoto, entityId: nil, op: .delete, payload: payload)
        now = queued.createdAt.addingTimeInterval(SyncRunner.photoTombstoneGrace + 1)
        await run(makeRunner())
        XCTAssertTrue(client.deleted.isEmpty)
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
    }

    /// The user signs out (local rows are wiped) while a batch runs: the
    /// rest of the batch must not go out under the next account, and a
    /// row missing after the upload is the wipe, not a delete by the
    /// user.
    func testAccountChangeDuringBatch_StopsAndQueuesNoDelete() async throws {
        let first = try seed(pushed: true)
        _ = try seed(pushed: true, sameSample: true)
        client.duringUpload = { [unowned self] in
            self.account = "user-b"
            try? self.photos.delete(id: first.id)
        }
        await run(makeRunner())
        XCTAssertEqual(client.attempts, 1, "kein weiterer Upload unter dem neuen Konto")
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty, "kein Löschauftrag durch den Kontowechsel")
    }

    func testTombstone_LookupFailureKeepsItForRetry() async throws {
        let payload = try JSONEncoder().encode(PhotoDeletePayload(clientUUID: "uuid-lost"))
        _ = try mutations.enqueue(entityType: .samplePhoto, entityId: nil, op: .delete, payload: payload)
        client.lookupError = URLError(.notConnectedToInternet)
        await run(makeRunner())
        XCTAssertEqual(try mutations.fetch(entityType: .samplePhoto).count, 1)
    }

    func testDeleteMutation_404CountsAsDone() async throws {
        _ = try mutations.enqueue(entityType: .samplePhoto, entityId: "pbphoto-9", op: .delete, payload: Data("{}".utf8))
        client.deleteError = SampleClientError.http(status: 404, body: "")
        await run(makeRunner())
        XCTAssertTrue(try mutations.fetch(entityType: .samplePhoto).isEmpty)
    }

    func testDeleteMutation_ServerErrorKeepsItForRetry() async throws {
        _ = try mutations.enqueue(entityType: .samplePhoto, entityId: "pbphoto-9", op: .delete, payload: Data("{}".utf8))
        client.deleteError = SampleClientError.http(status: 500, body: "")
        await run(makeRunner())
        XCTAssertEqual(try mutations.fetch(entityType: .samplePhoto).count, 1)
    }
}

private final class FakePhotoClient: PhotoSyncClient, @unchecked Sendable {
    struct Upload {
        let sampleBackendID: String
        let clientUUID: String
        let bytes: Data?
    }

    var uploads: [Upload] = []
    var attempts = 0
    var deleted: [String] = []
    /// Thrown by the next upload, then cleared.
    var nextError: Error?
    var deleteError: Error?
    var duringUpload: (() -> Void)?

    var cellularAllowed: [Bool] = []
    var lookups: [String] = []
    /// client uuid → backend id of records "on the server".
    var known: [String: String] = [:]
    var lookupError: Error?

    func findID(clientUUID: String) async throws -> String? {
        lookups.append(clientUUID)
        if let lookupError { throw lookupError }
        return known[clientUUID]
    }

    func upload(
        sampleBackendID: String, clientUUID: String, clientUpdatedAt _: Date, fileURL: URL, allowsCellularAccess: Bool
    ) async throws -> SamplePhotoResponse {
        attempts += 1
        cellularAllowed.append(allowsCellularAccess)
        duringUpload?()
        if let error = nextError {
            nextError = nil
            throw error
        }
        uploads.append(Upload(sampleBackendID: sampleBackendID, clientUUID: clientUUID, bytes: try? Data(contentsOf: fileURL)))
        return SamplePhotoResponse(id: "pbphoto-\(uploads.count)", sample: sampleBackendID, photoFile: "photo.jpg")
    }

    func delete(id: String) async throws {
        if let deleteError { throw deleteError }
        deleted.append(id)
    }
}

/// The photo tests queue no sample mutations; any call is a bug.
private struct NoSampleClient: SamplePushClient {
    struct Unexpected: Error {}

    func createSample(_: SampleCreateInput) async throws -> Sample {
        throw Unexpected()
    }

    func updateSample(id _: String, input _: SampleUpdateInput) async throws -> Sample {
        throw Unexpected()
    }

    func fetchSample(id _: String) async throws -> Sample {
        throw Unexpected()
    }

    func deleteSample(id _: String) async throws {
        throw Unexpected()
    }
}
