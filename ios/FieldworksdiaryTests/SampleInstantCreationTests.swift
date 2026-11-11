@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

@MainActor
private final class SilentFixSource: PendingFixSource {
    var onFix: (@MainActor (LocationProvider.Fix) -> Void)?
    private(set) var running = false
    func start() { running = true }
    func stop() { running = false }
    func emit(_ fix: LocationProvider.Fix) { onFix?(fix) }
}

/// Phase E: instant creation on the home screen and the editor that
/// saves on back (`finishEditing`) / in the background (`saveEdits`).
@MainActor
final class SampleInstantCreationTests: XCTestCase {
    private var database: Database!
    private var defaults: UserDefaults!
    private var samples: LocalSampleStore!
    private var photos: LocalPhotoStore!
    private var fieldtrips: LocalFieldtripStore!
    private var localities: LocalLocalityStore!
    private var mutations: PendingMutationsStore!
    private var sync: SyncRunner!
    private var fixSource: SilentFixSource!
    private var pendingFixes: PendingFixService!
    private var format = SampleIDTemplate.default.raw
    private let suiteName = "SampleInstantCreationTests"
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        format = SampleIDTemplate.default.raw
        samples = LocalSampleStore(
            database: database, userId: "u1", timeZone: berlin, defaults: defaults,
            settings: { [unowned self] in
                SampleIDSettings(
                    format: format, prefix: "JB", cutoffHour: 5,
                    lastRunning: defaults.integer(forKey: SampleIDSettings.Keys.lastRunning)
                )
            }
        )
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
        fixSource = SilentFixSource()
        pendingFixes = PendingFixService(
            store: samples, mutations: mutations, source: fixSource, defaults: defaults, timerInterval: nil
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        pendingFixes = nil
        fixSource = nil
        sync = nil
        mutations = nil
        localities = nil
        fieldtrips = nil
        photos = nil
        samples = nil
        defaults = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - createSample

    func testCreateSample_WithoutFix_InsertsSampleQueuesCreateAndRegistersFix() throws {
        let home = makeHome(fix: nil)

        let created = try XCTUnwrap(home.createSample())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertFalse(stored.hasCoordinate, "no fix yet → no coordinate")
        XCTAssertFalse(stored.sampleID.isEmpty, "id suggestion is stored")
        XCTAssertEqual(stored.timezone, "Europe/Berlin")
        XCTAssertEqual(stored.endDate?.timeIntervalSince(stored.beginDate), 15 * 60)
        let creates = try mutations.fetch(entityType: .sample).filter { $0.op == .create }
        XCTAssertEqual(creates.map(\.entityId), [created.id])
        XCTAssertEqual(pendingFixes.pendingCount, 1, "PendingFixService waits for the fix")
        XCTAssertEqual(home.sampleCount, 1)
    }

    func testCreateSample_WithFix_StoresCoordinateAndFusesLocality() throws {
        let fix = LocationProvider.Fix(latitude: 49.79, longitude: 9.94, horizontalAccuracy: 8,
                                       verticalAccuracy: 4, altitude: 180)
        let home = makeHome(fix: fix)

        let created = try XCTUnwrap(home.createSample())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.latitude, 49.79)
        XCTAssertEqual(stored.longitude, 9.94)
        XCTAssertEqual(stored.elevation, 180)
        XCTAssertEqual(stored.verticalAccuracy, 4)
        XCTAssertNotNil(stored.locality, "offline fusion like the old field save")
        XCTAssertEqual(try mutations.fetch(entityType: .locality).count, 1)
        XCTAssertEqual(try mutations.fetch(entityType: .sample).filter { $0.op == .create }.count, 1)
        XCTAssertEqual(pendingFixes.pendingCount, 0)
    }

    func testCreateSample_DoubleTap_CreatesOneSample() throws {
        let home = makeHome(fix: nil)

        XCTAssertNotNil(home.createSample())
        XCTAssertNil(home.createSample(), "editor push in flight → second tap ignored")

        XCTAssertEqual(try samples.count(), 1)
        home.newSample = nil // editor popped
        XCTAssertNotNil(home.createSample())
        XCTAssertEqual(try samples.count(), 2)
    }

    func testLateFix_FusesLocalityAndInheritsPlaceOffline() async throws {
        let noon = berlinDate("2026-06-05T12:00:00")
        var earlier = try samples.createLocal(lat: 49.0, lon: 9.0, collectedFrom: noon.addingTimeInterval(-600))
        earlier.placemark = "pm-earlier"
        try samples.update(earlier)

        let placemarks = LocalPlacemarkStore(database: database)
        let features = LocalSampleFeatureStore(database: database)
        let resolver = SampleLocationResolver(ortus: nil, samples: samples, placemarks: placemarks,
                                              features: features, mutations: mutations)
        let done = expectation(description: "late fix pipeline")
        pendingFixes = PendingFixService(
            store: samples, mutations: mutations, source: fixSource, defaults: defaults, timerInterval: nil,
            onCoordinateSet: { [unowned self] id in
                SampleCreation.completeLateFix(
                    sampleID: id, store: samples, localitiesStore: localities,
                    mutationsStore: mutations, resolver: resolver, sync: sync,
                    completion: { done.fulfill() }
                )
            }
        )
        let created = try XCTUnwrap(makeHome(fix: nil).createSample(now: noon))
        XCTAssertNil(try samples.fetchById(created.id)?.locality)

        fixSource.emit(LocationProvider.Fix(latitude: 49.79, longitude: 9.94, horizontalAccuracy: 8,
                                            verticalAccuracy: 4, altitude: 180))
        await fulfillment(of: [done], timeout: 2)

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.latitude, 49.79)
        XCTAssertNotNil(stored.locality, "fused like a sample created with a fix")
        XCTAssertEqual(try mutations.fetch(entityType: .locality).count, 1)
        XCTAssertEqual(stored.placemark, "pm-earlier", "offline → place of the earlier sample of the day")
        XCTAssertEqual(stored.locationStatus, .inherited)
    }

    func testMapPickOnNewSampleOffline_FusesLocalityAndInheritsPlace() async throws {
        let noon = berlinDate("2026-06-05T12:00:00")
        var earlier = try samples.createLocal(lat: 49.0, lon: 9.0, collectedFrom: noon.addingTimeInterval(-600))
        earlier.placemark = "pm-earlier"
        try samples.update(earlier)
        let created = try XCTUnwrap(makeHome(fix: nil).createSample(now: noon))
        let resolver = SampleLocationResolver(
            ortus: nil, samples: samples, placemarks: LocalPlacemarkStore(database: database),
            features: LocalSampleFeatureStore(database: database), mutations: mutations
        )
        // Phase N: the map pick lives in the edit form, through the
        // shared `CoordinateCorrection`.
        let correction = CoordinateCorrection(
            store: samples, localitiesStore: localities, mutationsStore: mutations, resolver: resolver, sync: sync
        )

        XCTAssertFalse(correction.request(sampleID: created.id, .init(latitude: 49.79, longitude: 9.94)))
        XCTAssertTrue(correction.apply(sampleID: created.id, keepManualPlace: true) {})

        var stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.latitude, 49.79)
        XCTAssertNotNil(stored.locality, "offline map pick fuses like a late fix")
        let locality = try XCTUnwrap(localities.fetchById(try XCTUnwrap(stored.locality)))
        XCTAssertEqual(locality.locationSource, LocationSource.user.rawValue)
        XCTAssertEqual(try mutations.fetch(entityType: .locality).map(\.op), [.create])
        for _ in 0 ..< 100 where stored.placemark == nil {
            try await Task.sleep(for: .milliseconds(10))
            stored = try XCTUnwrap(samples.fetchById(created.id))
        }
        XCTAssertEqual(stored.placemark, "pm-earlier", "offline → place of the earlier sample of the day")
        XCTAssertEqual(stored.locationStatus, .inherited)
    }

    // MARK: - pending fix state in the editor

    func testEditor_NewSampleWithoutCoordinate_LocatingUntilServiceGivesUp() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())

        let fresh = makeVM(created)
        XCTAssertEqual(fresh.locationStatus, .locating)
        fresh.endPendingFix()
        XCTAssertEqual(fresh.locationStatus, .idle)

        let late = SampleEditorViewModel(
            sampleID: created.id, isNew: true, store: samples, photoStore: photos,
            fieldtripStore: fieldtrips, mutationsStore: mutations,
            sync: sync, now: { Date().addingTimeInterval(PendingFixService.timeLimit + 1) }
        )
        XCTAssertEqual(late.locationStatus, .idle, "past the 5 minutes nobody is locating")
    }

    func testEditor_RetrospectiveSampleWithoutCoordinate_IsNotLocating() throws {
        let created = try samples.createRetrospective(
            code: "260519/1", latitude: nil, longitude: nil, beginDate: Date(),
            timezone: "Europe/Berlin", timezoneSource: .device, mutationsStore: mutations
        )

        let vm = makeVM(sampleID: created.id, isNew: true)

        XCTAssertEqual(vm.locationStatus, .idle, "nobody locates for a photo without GPS")
    }

    // MARK: - finishEditing

    func testFinishEditing_SavesNotes() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)

        vm.notes = "unter Steinen"
        XCTAssertTrue(vm.finishEditing())

        XCTAssertEqual(try samples.fetchById(created.id)?.notes, "unter Steinen")
        XCTAssertNil(vm.idPrompt)
        XCTAssertTrue(vm.finished)
    }

    func testFinishEditing_KeepsCoordinateWrittenMeanwhile() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        vm.notes = "getippt, während der Fix kommt"
        // PendingFixService writes the fix while the editor is open.
        try samples.updateCoordinate(
            id: created.id, latitude: 47.5, longitude: 11.5, horizontalAccuracy: 9,
            locationSource: .locationService, mutationsStore: mutations
        )

        XCTAssertTrue(vm.finishEditing())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.latitude, 47.5)
        XCTAssertEqual(stored.longitude, 11.5)
        XCTAssertEqual(stored.notes, "getippt, während der Fix kommt")
    }

    func testFinishEditing_NewSampleWithEmptyID_AsksForID() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        let suggested = vm.code

        vm.code = ""
        XCTAssertFalse(vm.finishEditing())

        XCTAssertEqual(vm.idPrompt, .emptyID)
        XCTAssertFalse(vm.finished)
        XCTAssertEqual(try samples.fetchById(created.id)?.sampleID, suggested, "nothing written yet")
    }

    func testEmptyIDPrompt_EnteredUniqueID_SavesAndFinishes() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        vm.code = ""
        vm.notes = "n"
        _ = vm.finishEditing()

        vm.promptedID = "JB-77"
        XCTAssertTrue(vm.submitPromptedID())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.sampleID, "JB-77")
        XCTAssertEqual(stored.notes, "n")
    }

    func testEmptyIDPrompt_EnteredIDTakenOrEmpty_NotSaved() throws {
        let other = try samples.createLocal(lat: 1, lon: 2, overrideCode: "JB-1")
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        vm.code = ""
        _ = vm.finishEditing()

        vm.promptedID = other.sampleID
        XCTAssertFalse(vm.submitPromptedID())
        XCTAssertEqual(vm.promptReason, "„JB-1“ ist bereits vergeben.")
        vm.promptedID = "  "
        XCTAssertFalse(vm.submitPromptedID())
        XCTAssertEqual(vm.promptReason, "Bitte eine Sample-ID eingeben.")

        XCTAssertNotEqual(try samples.fetchById(created.id)?.sampleID, "JB-1")
        XCTAssertFalse(vm.finished)
    }

    func testEmptyIDPrompt_DeleteSample_DeletesLocallyAndDropsCreate() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        vm.code = ""
        _ = vm.finishEditing()

        XCTAssertEqual(pendingFixes.pendingCount, 1)

        XCTAssertTrue(vm.deleteNewSample())

        XCTAssertNil(try samples.fetchById(created.id))
        XCTAssertEqual(try mutations.fetch(entityType: .sample).count, 0, "never pushed → nothing for the server")
        XCTAssertTrue(vm.finished)
        XCTAssertEqual(pendingFixes.pendingCount, 0, "deleted → no longer waiting for a fix")
    }

    func testEmptyIDPrompt_DeleteSample_DropsLocalityFusedForIt() throws {
        let fix = LocationProvider.Fix(latitude: 49.79, longitude: 9.94, horizontalAccuracy: 8,
                                       verticalAccuracy: 4, altitude: 180)
        let created = try XCTUnwrap(makeHome(fix: fix).createSample())
        let localityID = try XCTUnwrap(samples.fetchById(created.id)?.locality)
        let vm = makeVM(created)
        vm.code = ""
        _ = vm.finishEditing()

        XCTAssertTrue(vm.deleteNewSample())

        XCTAssertNil(try localities.fetchById(localityID), "no empty locality left behind")
        XCTAssertEqual(try mutations.fetch(entityType: .locality).count, 0, "its queued create is gone too")
    }

    func testEmptyIDPrompt_DeleteSample_AlreadyPushed_QueuesServerDelete() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        var row = try XCTUnwrap(samples.fetchById(created.id))
        row.backendId = "backend-9"
        row.syncStatus = .synced
        try samples.update(row)
        let vm = makeVM(created)
        vm.code = ""
        _ = vm.finishEditing()

        XCTAssertTrue(vm.deleteNewSample())

        XCTAssertNil(try samples.fetchById(created.id))
        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.map(\.op), [.delete])
        XCTAssertEqual(queued.first?.entityId, "backend-9")
    }

    func testDuplicateID_PromptsAndKeepPreviousSavesTheRest() throws {
        let other = try samples.createLocal(lat: 1, lon: 2, overrideCode: "JB-1")
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        let previous = vm.code

        vm.code = other.sampleID
        vm.notes = "Rest"
        XCTAssertFalse(vm.finishEditing())
        XCTAssertEqual(vm.idPrompt, .duplicate)

        XCTAssertTrue(vm.keepPreviousID())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.sampleID, previous)
        XCTAssertEqual(stored.notes, "Rest")
        XCTAssertEqual(vm.code, previous)
        XCTAssertTrue(vm.finished)
    }

    func testDuplicateID_Correct_StaysWithoutSaving() throws {
        let other = try samples.createLocal(lat: 1, lon: 2, overrideCode: "JB-1")
        let seeded = try samples.createLocal(lat: 1, lon: 2, overrideCode: "JB-2")
        let vm = makeVM(sampleID: seeded.id)

        vm.code = other.sampleID
        XCTAssertFalse(vm.finishEditing(), "existing samples are checked too")
        XCTAssertEqual(vm.idPrompt, .duplicate)
        vm.correctID()

        XCTAssertNil(vm.idPrompt)
        XCTAssertFalse(vm.finished)
        XCTAssertEqual(try samples.fetchById(seeded.id)?.sampleID, "JB-2")
    }

    func testExistingSampleWithEmptyID_NoPrompt() throws {
        let seeded = try samples.createLocal(lat: 1, lon: 2, overrideCode: "JB-2")
        let vm = makeVM(sampleID: seeded.id)

        vm.code = ""
        vm.notes = "Altdaten"
        XCTAssertTrue(vm.finishEditing())

        XCTAssertNil(vm.idPrompt)
        let stored = try XCTUnwrap(samples.fetchById(seeded.id))
        XCTAssertEqual(stored.sampleID, "")
        XCTAssertEqual(stored.notes, "Altdaten")
    }

    // MARK: - background save

    func testBackgroundSave_EmptyIDOfNewSample_KeepsStoredIDSavesNotes() throws {
        let created = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm = makeVM(created)
        let suggested = vm.code

        vm.code = ""
        vm.notes = "Hintergrund"
        XCTAssertTrue(vm.saveEdits())

        let stored = try XCTUnwrap(samples.fetchById(created.id))
        XCTAssertEqual(stored.sampleID, suggested)
        XCTAssertEqual(stored.notes, "Hintergrund")
        XCTAssertEqual(vm.code, "", "the empty id stays in the field until back")
        XCTAssertNil(vm.idPrompt, "no dialog in the background")
    }

    // MARK: - running counter (Phase Z rule)

    func testRunningCounter_AdvancesOnlyWhenSuggestionKept() throws {
        format = "<PREFIX><n>"
        let first = try XCTUnwrap(makeHome(fix: nil).createSample())
        XCTAssertEqual(first.suggestedRunning, 1)
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 0,
                       "creation alone doesn't consume the number")
        let vm1 = makeVM(first)
        XCTAssertEqual(vm1.code, "JB1")
        XCTAssertTrue(vm1.finishEditing())
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 1)

        let second = try XCTUnwrap(makeHome(fix: nil).createSample())
        let vm2 = makeVM(second)
        XCTAssertEqual(vm2.code, "JB2")
        vm2.code = "Röhrchen 17"
        XCTAssertTrue(vm2.finishEditing())
        XCTAssertEqual(defaults.integer(forKey: SampleIDSettings.Keys.lastRunning), 1,
                       "a replaced suggestion leaves the counter alone")
    }

    // MARK: - helpers

    private func berlinDate(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = berlin
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: iso) ?? Date()
    }

    private func makeHome(fix: LocationProvider.Fix?) -> HomeViewModel {
        HomeViewModel(
            auth: AuthSession(endpointProvider: { "" }),
            samples: samples,
            fieldtrips: fieldtrips,
            localities: localities,
            photos: photos,
            creator: InstantSampleCreator(
                store: samples,
                localitiesStore: localities,
                mutationsStore: mutations,
                sync: sync,
                pendingFixes: pendingFixes,
                locationResolver: nil,
                currentFix: { fix }
            )
        )
    }

    private func makeVM(_ created: InstantSampleCreator.Created) -> SampleEditorViewModel {
        makeVM(sampleID: created.id, isNew: true, suggestedRunning: created.suggestedRunning)
    }

    private func makeVM(sampleID: String, isNew: Bool = false, suggestedRunning: Int? = nil) -> SampleEditorViewModel {
        SampleEditorViewModel(
            sampleID: sampleID,
            isNew: isNew,
            suggestedRunning: suggestedRunning,
            store: samples,
            photoStore: photos,
            fieldtripStore: fieldtrips,
            mutationsStore: mutations,
            sync: sync,
            pendingFixes: pendingFixes
        )
    }
}
