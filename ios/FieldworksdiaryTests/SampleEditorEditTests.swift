@testable import Fieldworksdiary
import XCTest

/// Edit-Verhalten des `SampleEditorViewModel`: Dirty-Tracking,
/// `canSave`-Matrix, Code-Validierung, `saveEdits` → Outbox.
@MainActor
final class SampleEditorEditTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var photos: LocalPhotoStore!
    private var fieldtrips: LocalFieldtripStore!
    private var localities: LocalLocalityStore!
    private var mutations: PendingMutationsStore!
    private var sync: SyncRunner!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)
        photos = LocalPhotoStore(database: database)
        fieldtrips = LocalFieldtripStore(database: database)
        localities = LocalLocalityStore(database: database)
        mutations = PendingMutationsStore(database: database)
        sync = SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "" }, // no-op pass on kick()
            retryInterval: .seconds(3600)
        )
    }

    override func tearDownWithError() throws {
        database = nil
        samples = nil
        photos = nil
        fieldtrips = nil
        localities = nil
        mutations = nil
        sync = nil
        try super.tearDownWithError()
    }

    func testAdoptExisting_NoEdits_CanSaveFalse() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "hi")
        let vm = makeVM(sampleID: seeded.id)

        XCTAssertTrue(vm.isExistingSample)
        XCTAssertFalse(vm.hasUnsavedEdits)
        XCTAssertFalse(vm.canSave, "no dirty edits → disabled")
    }

    func testEdit_NotesDirty_CanSaveTrue() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "hi")
        let vm = makeVM(sampleID: seeded.id)

        vm.notes = "hello, edited"

        XCTAssertTrue(vm.hasUnsavedEdits)
        XCTAssertTrue(vm.canSave)
    }

    func testRecheckCode_Empty_NoError() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "")
        let vm = makeVM(sampleID: seeded.id)

        vm.code = ""
        vm.recheckCode()
        XCTAssertNil(vm.codeValidationError)
    }

    func testRecheckCode_Malformed_FormatError() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "")
        let vm = makeVM(sampleID: seeded.id)

        vm.code = "not-a-code"
        vm.recheckCode()
        XCTAssertNotNil(vm.codeValidationError)
        XCTAssertTrue(vm.codeValidationError?.contains("Format") ?? false)
        XCTAssertFalse(vm.canSave, "format error blocks save")
    }

    func testRecheckCode_DuplicateOfAnotherSample_UniquenessError() throws {
        let other = try seedSyncedSample(code: "260605/1", notes: "")
        let me = try seedSyncedSample(code: "260605/2", notes: "")
        let vm = makeVM(sampleID: me.id)

        // I try to take the code of the other sample.
        vm.code = other.sampleID
        vm.recheckCode()
        XCTAssertNotNil(vm.codeValidationError)
        XCTAssertTrue(vm.codeValidationError?.contains("bereits") ?? false)
    }

    func testRecheckCode_SelfCode_NoError() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "")
        let vm = makeVM(sampleID: seeded.id)

        // Re-entering the existing code (the typical "did not change
        // the code" case) must not flag a uniqueness collision against
        // the row itself.
        vm.code = seeded.sampleID
        vm.recheckCode()
        XCTAssertNil(vm.codeValidationError)
    }

    func testSaveEdits_EnqueuesUpdate_WhenBackendIdPresent() async throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "before", backendID: "backend-1")
        let vm = makeVM(sampleID: seeded.id)

        vm.notes = "after"
        await vm.saveEdits()

        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(
            updates[0].entityId, seeded.id,
            "entityId is the local UUID; backend id is read fresh at execute time"
        )
        // Payload is intentionally empty — SyncRunner reads the
        // freshest local row at PATCH time, so successive saves don't
        // need to coalesce or serialize state into the outbox.
        XCTAssertTrue(updates[0].payloadJson.isEmpty)
        // Local row reflects the edit immediately.
        let stored = try XCTUnwrap(samples.fetchById(seeded.id))
        XCTAssertEqual(stored.notes, "after")
    }

    func testAdoptExisting_WhitespaceTrimmed_NoFalseDirty() throws {
        // Legacy row with stray trailing whitespace must NOT open as
        // dirty — hasUnsavedEdits compared trimmed input against an
        // untrimmed snapshot before the fix.
        let seeded = try seedSyncedSample(code: "260605/1", notes: "hello \n")
        let vm = makeVM(sampleID: seeded.id)

        XCTAssertFalse(vm.hasUnsavedEdits, "trimmed snapshot must match trimmed input")
        XCTAssertFalse(vm.canSave)
    }

    // MARK: - helpers

    // MARK: - Task 17: coordinate correction, suggestion, resend

    func testCoordinateCorrection_ManualSample_AsksBeforeWriting() throws {
        var seeded = try seedSyncedSample(code: "260605/1", notes: "", backendID: "b1")
        seeded.locationStatus = .manual
        seeded.placemark = "pmmanual000001"
        try samples.update(seeded)
        let vm = makeVM(sampleID: seeded.id)

        vm.requestCoordinateCorrection(latitude: 47.0, longitude: 11.0)

        XCTAssertTrue(vm.askRetakePlace, "manual place ⇒ „Ortsangaben neu übernehmen?“")
        XCTAssertEqual(try samples.fetchById(seeded.id)?.latitude, 49.79, "nothing written before the answer")
        XCTAssertEqual(try mutations.count(), 0)

        vm.applyCoordinateCorrection(keepManualPlace: false)

        let stored = try XCTUnwrap(samples.fetchById(seeded.id))
        XCTAssertEqual(stored.latitude, 47.0)
        XCTAssertEqual(stored.locationStatus, .pending, "„Übernehmen“ drops the manual place")
        XCTAssertNil(stored.placemark)
        XCTAssertEqual(stored.locationSource, LocationSource.user.rawValue)
        XCTAssertFalse(vm.askRetakePlace)
    }

    func testCoordinateCorrection_ManualSample_KeepMyPlace() throws {
        var seeded = try seedSyncedSample(code: "260605/1", notes: "", backendID: "b1")
        seeded.locationStatus = .manual
        seeded.placemark = "pmmanual000001"
        try samples.update(seeded)
        let vm = makeVM(sampleID: seeded.id)

        vm.requestCoordinateCorrection(latitude: 47.0, longitude: 11.0)
        vm.applyCoordinateCorrection(keepManualPlace: true)

        let stored = try XCTUnwrap(samples.fetchById(seeded.id))
        XCTAssertEqual(stored.latitude, 47.0)
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertEqual(stored.placemark, "pmmanual000001")
    }

    func testCoordinateCorrection_NonManual_AppliesDirectly() throws {
        var seeded = try seedSyncedSample(code: "260605/1", notes: "", backendID: "b1")
        seeded.locationStatus = .backendService
        seeded.placemark = "pmbackend00001"
        try samples.update(seeded)
        let vm = makeVM(sampleID: seeded.id)

        vm.requestCoordinateCorrection(latitude: 47.0, longitude: 11.0)

        XCTAssertFalse(vm.askRetakePlace)
        let stored = try XCTUnwrap(samples.fetchById(seeded.id))
        XCTAssertEqual(stored.latitude, 47.0)
        XCTAssertEqual(stored.locationStatus, .pending)
        XCTAssertNil(stored.placemark)
        let queued = try XCTUnwrap(mutations.fetch(entityType: .sample).first)
        XCTAssertTrue(SampleUpdatePayload.decode(queued.payloadJson).coordinateChanged)
    }

    func testDismissSuggestion_FromEditor() throws {
        var seeded = try seedSyncedSample(code: "260605/1", notes: "", backendID: "b1")
        seeded.locationStatus = .manual
        seeded.placemark = "pmmanual000001"
        seeded.placemarkSuggestion = "pmsuggestion01"
        try samples.update(seeded)
        let vm = makeVM(sampleID: seeded.id)
        XCTAssertTrue(vm.hasSuggestion)

        vm.dismissSuggestion()

        XCTAssertFalse(vm.hasSuggestion)
        XCTAssertNil(try samples.fetchById(seeded.id)?.placemarkSuggestion)
    }

    func testResendFailed_FromEditor_RequeuesAndClearsFailedState() throws {
        let seeded = try seedSyncedSample(code: "260605/1", notes: "", backendID: "b1")
        try samples.setSyncState(id: seeded.id, status: .failed, error: "Konflikt")
        let vm = makeVM(sampleID: seeded.id)
        XCTAssertTrue(vm.canResend)

        vm.resendFailed()

        XCTAssertFalse(vm.canResend)
        XCTAssertEqual(try mutations.count(), 1)
        XCTAssertEqual(try samples.fetchById(seeded.id)?.syncStatus, .pending)
    }

    private func makeVM(sampleID: String?) -> SampleEditorViewModel {
        SampleEditorViewModel(
            sampleID: sampleID,
            store: samples,
            photoStore: photos,
            fieldtripStore: fieldtrips,
            localitiesStore: localities,
            mutationsStore: mutations,
            sync: sync
        )
    }

    private func seedSyncedSample(
        code: String,
        notes: String,
        backendID: String? = nil
    ) throws -> LocalSample {
        var sample = try samples.createLocal(lat: 49.79, lon: 9.94, notes: notes)
        sample.sampleID = code
        if let backendID {
            sample.backendId = backendID
            sample.syncStatus = .synced
        }
        try samples.update(sample)
        // swiftlint:disable:next force_unwrapping
        return try samples.fetchById(sample.id)!
    }
}
