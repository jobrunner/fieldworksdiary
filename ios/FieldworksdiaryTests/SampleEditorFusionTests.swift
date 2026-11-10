@testable import Fieldworksdiary
import XCTest

/// R8d: the offline-fusion branch in the sample editor. A field-mode
/// save must attach the sample to a nearby local locality, or — on a
/// miss — create a new local one and enqueue its `.locality/.create`
/// outbox mutation.
@MainActor
final class SampleEditorFusionTests: XCTestCase {
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
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        photos = LocalPhotoStore(database: database)
        fieldtrips = LocalFieldtripStore(database: database)
        localities = LocalLocalityStore(database: database)
        mutations = PendingMutationsStore(database: database)
        // Endpoint "" → sync.kick() runs an immediate no-op pass, so it
        // never touches the outbox we're asserting on.
        sync = SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "" },
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

    private func makeVM() -> SampleEditorViewModel {
        SampleEditorViewModel(
            sampleID: nil,
            store: samples,
            photoStore: photos,
            fieldtripStore: fieldtrips,
            localitiesStore: localities,
            mutationsStore: mutations,
            sync: sync
        )
    }

    /// „Probe nachtragen“ on the home screen opens the unsaved create
    /// path straight in `.later`; GPS must not start there.
    func testInitialModeLater_OpensNachtraeglichWithoutGPS() {
        let vm = SampleEditorViewModel(
            sampleID: nil,
            store: samples,
            photoStore: photos,
            fieldtripStore: fieldtrips,
            localitiesStore: localities,
            mutationsStore: mutations,
            sync: sync,
            initialMode: .later
        )
        XCTAssertEqual(vm.mode, .later)
        vm.startGPS()
        XCTAssertEqual(vm.mode, .later)
        XCTAssertFalse(vm.isExistingSample)
    }

    func testFieldModeMiss_CreatesNewLocalityAndEnqueuesMutation() async throws {
        let vm = makeVM()
        vm.mode = .field
        vm.setManualCoordinate(latitude: 49.79, longitude: 9.94)

        await vm.save()

        let localityMutations = try mutations.fetch(entityType: .locality)
        XCTAssertEqual(localityMutations.count, 1, "miss → one .locality/.create enqueued")
        let newLocalityID = try XCTUnwrap(localityMutations.first?.entityId)
        XCTAssertEqual(vm.savedSample?.locality, newLocalityID)
        XCTAssertNotNil(try localities.fetchById(newLocalityID))
    }

    func testFieldModeHit_AttachesExistingLocalityNoNewMutation() async throws {
        // Seed an existing local locality at the exact sample point.
        let existing = try localities.createLocal(latitude: 49.79, longitude: 9.94)

        let vm = makeVM()
        vm.mode = .field
        vm.setManualCoordinate(latitude: 49.79, longitude: 9.94)

        await vm.save()

        XCTAssertEqual(vm.savedSample?.locality, existing.id, "within 50 m → reuse")
        XCTAssertEqual(try mutations.fetch(entityType: .locality).count, 0,
                       "hit → no new locality create")
    }

    func testLaterModeSkipsFusion() async throws {
        let vm = makeVM()
        vm.mode = .later
        vm.setManualCoordinate(latitude: 49.79, longitude: 9.94)

        await vm.save()

        XCTAssertNil(vm.savedSample?.locality, "manual mode doesn't auto-fuse")
        XCTAssertEqual(try mutations.fetch(entityType: .locality).count, 0)
    }
}
