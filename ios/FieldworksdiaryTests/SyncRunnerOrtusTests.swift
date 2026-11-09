@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase O2 sync: placemark → sample → features on push, merging
/// server enrichment without losing local data, and hydrating
/// placemarks + features of samples the backend enriched.
@MainActor
final class SyncRunnerOrtusTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    private var placemarks: LocalPlacemarkStore!
    private var features: LocalSampleFeatureStore!
    private var log: CallLog!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private let place = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)
        mutations = PendingMutationsStore(database: database)
        placemarks = LocalPlacemarkStore(database: database)
        features = LocalSampleFeatureStore(database: database)
        log = CallLog()
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        placemarks = nil
        features = nil
        database = nil
        log = nil
        try super.tearDownWithError()
    }

    // MARK: - create

    func testCreate_ResolvesPlacemarkThenCreatesThenPutsFeatures() async throws {
        let sample = try seedResolvedSample()
        let localPlacemarkID = try XCTUnwrap(sample.placemark)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", elevation: 250, elevationSource: "location_service")
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        let fx = MockFeatures(log: log)

        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        XCTAssertEqual(log.calls, ["resolve", "create", "features"])
        XCTAssertEqual(pm.resolved.first?.source, .backendService)
        XCTAssertEqual(pm.resolved.first?.place, place)

        let sent = try XCTUnwrap(push.lastCreate)
        XCTAssertEqual(sent.location.placemark, "pmbackend00001", "backend id, never the local UUID")
        XCTAssertEqual(sent.location.locationStatus, .backendService)
        XCTAssertEqual(sent.location.elevation, 250)
        XCTAssertEqual(sent.location.elevationSource, .locationService)
        XCTAssertEqual(sent.location.locationSource, .locationService)
        XCTAssertEqual(sent.location.mtbSheetNumber, "6326")
        XCTAssertEqual(sent.location.mtbQuadrant, 1)
        XCTAssertEqual(sent.location.wireBody["placemark"] as? String, "pmbackend00001")

        XCTAssertEqual(fx.replaced.first?.sampleBackendID, "backend-1")
        XCTAssertEqual(fx.replaced.first?.features.count, 2)

        let row = try XCTUnwrap(placemarks.fetchById(localPlacemarkID))
        XCTAssertEqual(row.backendId, "pmbackend00001", "backend id remembered on the local row")
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, localPlacemarkID, "local reference stays the local row")
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.backendId, "backend-1")
    }

    func testCreate_AlreadyResolvedPlacemarkIsNotResolvedAgain() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(log.calls, ["create", "features"])
        XCTAssertEqual(push.lastCreate?.location.placemark, "pmbackend00001")
    }

    func testCreate_ManualPlacemarkResolvedAsOwnManualRow() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let manual = try placemarks.lookupOrCreate(place: place, source: .manual)
        sample.placemark = manual.id
        sample.locationStatus = .manual
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual")
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000001", source: "manual", owner: "u1")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        XCTAssertEqual(pm.resolved.first?.source, .manual)
        XCTAssertEqual(push.lastCreate?.location.placemark, "pmmanual000001")
        XCTAssertEqual(push.lastCreate?.location.locationStatus, .manual)
        XCTAssertEqual(try placemarks.fetchById(manual.id)?.owner, "u1")
    }

    func testCreate_UnknownLocalPlacemarkUUID_IsNotSentAndStatusFallsBackToPending() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.placemark = UUID().uuidString
        sample.locationStatus = .inherited
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastCreate?.location.placemark)
        XCTAssertEqual(push.lastCreate?.location.locationStatus, .pending,
                       "without its placemark the backend must enrich the sample itself")
    }

    func testCreate_KeepsLocalLocalityWhenServerReturnsNone() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.locality = "locbackend0001"
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastCreate?.location.locality, "locbackend0001")
        XCTAssertEqual(try store.fetchById(sample.id)?.locality, "locbackend0001")
    }

    func testCreate_ClientLocalityUUIDIsNotSent() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.locality = UUID().uuidString
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastCreate?.location.locality)
    }

    func testCreate_ManualHeightStaysManual() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14),
                                           locationSource: .user)
        sample.elevation = 512
        sample.elevationSource = .manual
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID,
                                     elevation: 512, elevationSource: "manual")
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastCreate?.location.elevationSource, .manual)
        XCTAssertEqual(push.lastCreate?.location.wireBody["elevation_source"] as? String, "manual")
        XCTAssertEqual(push.lastCreate?.location.locationSource, .user)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.elevationSource, .manual)
        XCTAssertEqual(stored.elevation, 512)
    }

    func testCreate_ServerWithoutEnrichment_KeepsLocalMTBAndGeo() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)

        let push = MockPush(log: log)
        // Server echo without geo columns (e.g. older server build).
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.mtbSheetNumber, "6326")
        XCTAssertEqual(stored.mtbSheetName, "Ochsenfurt")
        XCTAssertEqual(stored.mtbQuadrant, 1)
        XCTAssertEqual(stored.bearingLabel, "Ochsenfurt")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.placemark, sample.placemark)
    }

    func testCreate_EditDuringPost_IsKeptAndQueuedAsUpdate() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        // The on-device resolver lands while the POST is in flight.
        push.duringCreate = { [store] in
            guard var row = try? store?.fetchById(sample.id) else { return }
            row.mtbSheetNumber = "6326"
            row.locationStatus = .inherited
            row.placemark = "pminherited001"
            try? store?.update(row)
        }
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.mtbSheetNumber, "6326", "stale pre-POST copy must not overwrite")
        XCTAssertEqual(stored.locationStatus, .inherited)
        XCTAssertEqual(stored.placemark, "pminherited001")
        XCTAssertEqual(stored.backendId, "backend-1")
        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.map(\.entityId), [sample.id], "missed edit goes out as update")
    }

    func testCreate_FeaturesPutFails_QueuesFeatureUpdate() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        let fx = MockFeatures(log: log)
        fx.replaceError = SampleClientError.http(status: 500, body: "")
        await runUntilQuiescent(makeRunner(push: push, features: fx))

        let update = try XCTUnwrap(mutations.fetch(entityType: .sample).first { $0.op == .update })
        XCTAssertTrue(SampleUpdatePayload.decode(update.payloadJson).pushFeatures)
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
    }

    // MARK: - update

    func testUpdate_NewCoordinate_SendsCoordinateAndPendingStatus() async throws {
        let sample = try seedSyncedSample(status: .backendService)
        try store.updateCoordinate(id: sample.id, latitude: 49.70, longitude: 10.10,
                                   mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending", version: 3,
                                     lat: 49.70, lon: 10.10)
        // The backend re-enriches the moved sample and bumps the version.
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00002", version: 4, mtb: "6327",
                                    lat: 49.70, lon: 10.10)
        await runUntilQuiescent(makeRunner(push: push))

        let sent = try XCTUnwrap(push.lastUpdate)
        XCTAssertEqual(sent.location.latitude, 49.70)
        XCTAssertEqual(sent.location.longitude, 10.10)
        XCTAssertEqual(sent.location.locationStatus, .pending)
        XCTAssertEqual(sent.location.locationSource, .user)
        let body = sent.location.wireBody
        XCTAssertEqual(body["location_status"] as? String, "pending")
        XCTAssertEqual(body["mtb_sheet_number"] as? String, "", "old point's MTB is cleared, not re-sent")
        XCTAssertEqual(body["placemark"] as? String, "")
        XCTAssertEqual(body["bearing_inside"] as? Bool, false)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.version, 4, "follows the enrichment bump, next edit won't 409")
        XCTAssertEqual(stored.placemark, "pmbackend00002")
        XCTAssertEqual(stored.mtbSheetNumber, "6327")
        XCTAssertEqual(stored.locationStatus, .backendService)
    }

    func testUpdateCoordinate_ClearsDerivedValuesButKeepsGPSHeight() throws {
        let sample = try seedResolvedSample()
        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertNil(stored.mtbSheetNumber)
        XCTAssertNil(stored.mtbSheetName)
        XCTAssertNil(stored.mtbQuadrant)
        XCTAssertNil(stored.bearingLabel)
        XCTAssertFalse(stored.bearingInside)
        XCTAssertNil(stored.placemark)
        XCTAssertEqual(stored.locationStatus, .pending)
        XCTAssertEqual(stored.elevation, 250, "GPS height is the device's own, not derived")
        XCTAssertEqual(try features.count(sampleID: sample.id), 0)
        XCTAssertEqual(try mutations.count(), 0, "unpushed row: the pending create carries it")
    }

    func testUpdateCoordinate_ManualKeepsPlacemarkAndClearsDEMHeight() throws {
        var sample = try seedResolvedSample()
        sample.locationStatus = .manual
        sample.placemarkSuggestion = "pmsuggestion01"
        sample.elevationSource = .backendService
        sample.elevationDEM = 250
        try store.update(sample)

        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertEqual(stored.placemark, sample.placemark)
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertNil(stored.elevation)
        XCTAssertNil(stored.elevationSource)
        XCTAssertNil(stored.elevationDEM)
    }

    func testUpdate_WeakLocalStatus_TakesServerEnrichmentInsteadOfReverting() async throws {
        var sample = try seedSyncedSample(status: .pending)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 3, mtb: "6326")
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 4, mtb: "6326")
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{}", licenseJSON: nil)
        ]
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        let sent = try XCTUnwrap(push.lastUpdate)
        XCTAssertEqual(sent.location.locationStatus, .backendService, "never push pending over the enrichment")
        XCTAssertEqual(sent.location.placemark, "pmbackend00001")
        XCTAssertEqual(sent.version, 4, "server version 3 + 1")
        XCTAssertEqual(sent.notes, "edit")
        XCTAssertEqual(try features.count(sampleID: sample.id), 1, "features hydrated after enrichment")
        XCTAssertNotNil(try placemarks.fetchById("pmbackend00001"))
    }

    func testPoll_WithQueuedEdit_MergesPlaceDataSoTheEditDoesNotRevertIt() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 2, mtb: "6326")
        // The user edits the notes while the poll waits.
        push.duringFetch = { [store, mutations] in
            guard var row = try? store?.fetchById(sample.id), let mutations else { return }
            row.notes = "edit"
            try? store?.saveEdits(row, mutationsStore: mutations)
        }
        let runner = makeRunner(push: push)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.version, 2)
        XCTAssertEqual(stored.notes, "edit")

        push.duringFetch = nil
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        try? await Task.sleep(for: .milliseconds(20))
        await runUntilQuiescent(runner)
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .backendService)
        XCTAssertEqual(push.lastUpdate?.location.placemark, "pmbackend00001")
        XCTAssertEqual(push.lastUpdate?.version, 3)
    }

    func testSaveEdits_StaleEditorSnapshotKeepsVersionAndPlaceData() throws {
        let stale = try seedSyncedSample(status: .pending)
        var merged = stale
        merged.version = 5
        merged.placemark = "pmbackend00001"
        merged.locationStatus = .backendService
        try store.update(merged)

        var edited = stale
        edited.notes = "from the editor"
        try store.saveEdits(edited, mutationsStore: mutations)
        try store.update(stale) // a whole-row write with the old counter

        let row = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(row.version, 5, "versions only move forward")
        XCTAssertEqual(try XCTUnwrap(store.fetchById(stale.id)).version, 5)
        var afterEdit = row
        afterEdit.notes = "again"
        try store.saveEdits(afterEdit, mutationsStore: mutations)
        let final = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(final.notes, "again")
        XCTAssertEqual(final.version, 5)
    }

    func testSaveEdits_WritesOnlyUserFields() throws {
        let stale = try seedSyncedSample(status: .pending)
        var merged = stale
        merged.placemark = "pmbackend00001"
        merged.locationStatus = .backendService
        merged.mtbSheetNumber = "6326"
        try store.update(merged)

        var edited = stale
        edited.notes = "from the editor"
        try store.saveEdits(edited, mutationsStore: mutations)

        let row = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(row.notes, "from the editor")
        XCTAssertEqual(row.placemark, "pmbackend00001")
        XCTAssertEqual(row.locationStatus, .backendService)
        XCTAssertEqual(row.mtbSheetNumber, "6326")
    }

    func testReconcile_FailedPushedRowIsNotReadoptedAsCreate() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.syncStatus = .failed
        try store.update(sample)

        let push = MockPush(log: log)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(try mutations.count(), 0)
    }

    func testUpdate_NewCoordinateOnManualSample_KeepsManual() async throws {
        let sample = try seedSyncedSample(status: .manual)
        try store.updateCoordinate(id: sample.id, latitude: 49.70, longitude: 10.10,
                                   mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual)
    }

    func testUpdate_FeaturePayload_OrderPlacemarkPatchFeatures() async throws {
        var sample = try seedSyncedSample(status: .pending)
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        sample.placemark = local.id
        sample.locationStatus = .backendService
        try store.update(sample)
        try features.replace(sampleID: sample.id, features: [feature("a")])
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                  payload: SampleUpdatePayload(pushFeatures: true).encoded)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        let fx = MockFeatures(log: log)
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        XCTAssertEqual(log.calls, ["resolve", "update", "features"])
        XCTAssertEqual(push.lastUpdate?.location.placemark, "pmbackend00001")
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .backendService)
        XCTAssertEqual(fx.replaced.first?.features.count, 1)
        XCTAssertEqual(try mutations.count(), 0)
    }

    func testUpdate_PlainEdit_DoesNotPutFeatures() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        try features.replace(sampleID: sample.id, features: [feature("a")])
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(log.calls, ["update"])
    }

    // MARK: - Task 17 place edits on the wire

    func testUpdate_DismissedSuggestion_SendsExplicitEmptyRelation() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = "pmsuggestion01"
        try store.update(sample)
        try store.dismissPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000001", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        let body = try XCTUnwrap(push.lastUpdate?.location.wireBody)
        XCTAssertEqual(body["placemark_suggestion"] as? String, "", "server must drop its suggestion too")
        XCTAssertEqual(body["placemark"] as? String, "pmmanual000001")
        XCTAssertEqual(body["location_status"] as? String, "manual")
        XCTAssertNil(body["mtb_sheet_number"], "no coordinate clears on a suggestion clear")
        XCTAssertNil(try store.fetchById(sample.id)?.placemarkSuggestion)
    }

    func testUpdate_PlainEdit_DoesNotClearSuggestion() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        try store.update(sample)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastUpdate?.location.wireBody["placemark_suggestion"])
    }

    func testUpdate_AcceptedLocalSuggestion_IsResolvedAndSentAsPlacemark() async throws {
        let pmRow = try placemarks.lookupOrCreate(place: place, source: .backendService)
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = pmRow.id
        try store.update(sample)
        try store.acceptPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        let body = try XCTUnwrap(push.lastUpdate?.location.wireBody)
        XCTAssertEqual(body["placemark"] as? String, "pmbackend00001")
        XCTAssertEqual(body["placemark_suggestion"] as? String, "")
        XCTAssertEqual(body["location_status"] as? String, "backend_service")
    }

    func testUpdate_ManualPlaceFromEditor_IsResolvedAsManual() async throws {
        let sample = try seedSyncedSample(status: .backendService)
        _ = try store.setManualPlace(id: sample.id, place: place, placemarks: placemarks,
                                     mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000009", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000009", source: "manual", owner: "u1")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        XCTAssertEqual(pm.resolved.first?.source, .manual)
        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark"] as? String, "pmmanual000009")
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual)
    }

    func testResendFailed_AfterGivingUp_PushesTheKeptEdit() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.notes = "kept edit"
        try store.update(sample)
        try store.setSyncState(id: sample.id, status: .failed, error: "Konflikt")
        try store.resendFailed(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastUpdate?.notes, "kept edit")
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
        XCTAssertEqual(try mutations.count(), 0)
    }

    // MARK: - hydration / enrichment

    func testHydration_OfflineSampleEnrichedByBackend_GetsPlacemarkAndFeatures() async throws {
        // Saved offline, pushed as pending, enriched by the backend.
        let sample = try seedSyncedSample(status: .pending)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 2,
                             mtb: "6326")]
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{\"name\":\"A\"}", licenseJSON: nil),
            RemoteSampleFeature(id: "f2", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "2", propertiesJSON: "{}", licenseJSON: "{\"id\":\"CC-BY\"}")
        ]
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.mtbSheetNumber, "6326")
        XCTAssertEqual(stored.version, 2)
        let row = try XCTUnwrap(placemarks.fetchById("pmbackend00001"))
        XCTAssertEqual(row.place, place, "Ortus columns hydrated, not blank")
        XCTAssertEqual(try features.all(sampleID: sample.id).map(\.featureID), ["1", "2"])
        XCTAssertEqual(pm.fetchedIDs, [["pmbackend00001"]])
        XCTAssertEqual(fx.fetchedIDs, [["backend-1"]])
    }

    func testHydration_PlacemarkKnownViaBackendID_MapsToLocalRowAndKeepsOrtusColumns() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        try placemarks.setBackend(localID: local.id, backendID: "pmbackend00001", owner: nil)
        sample.placemark = local.id
        try store.update(sample)
        try features.replace(sampleID: sample.id, features: [feature("a")])

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 2)]
        let pm = MockPlacemarks(log: log)
        let fx = MockFeatures(log: log)
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        XCTAssertEqual(try store.fetchById(sample.id)?.placemark, local.id)
        XCTAssertTrue(pm.fetchedIDs.isEmpty, "known placemark is not fetched again")
        XCTAssertTrue(fx.fetchedIDs.isEmpty, "local features present → no fetch")
        XCTAssertEqual(try placemarks.count(), 1)
    }

    func testHydration_DirtyRowIsNotOverwritten() async throws {
        var sample = try seedSyncedSample(status: .pending)
        sample.notes = "local edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 5)]
        let hydrator = SamplesHydrator(
            store: store, endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list }
        )
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.notes, "local edit")
        XCTAssertEqual(stored.locationStatus, .pending)
    }

    func testHydration_KeepsClientLocalityWhoseLocalityPushIsPending() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        let clientLocality = UUID().uuidString
        sample.locality = clientLocality
        try store.update(sample)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", version: 2)]
        let hydrator = SamplesHydrator(store: store, endpointProvider: { "http://test.invalid" },
                                       clientFactory: { _, _ in list })
        await hydrator.pull()

        XCTAssertEqual(try store.fetchById(sample.id)?.locality, clientLocality)
    }

    func testHydration_OlderSnapshotThanLocalIsIgnored() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.version = 5
        sample.notes = "pushed edit"
        try store.update(sample)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", version: 3)]
        let hydrator = SamplesHydrator(store: store, endpointProvider: { "http://test.invalid" },
                                       clientFactory: { _, _ in list })
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.version, 5)
        XCTAssertEqual(stored.notes, "pushed edit")
    }

    func testUpsertPlacemark_ServerRowWithoutOrtusColumns_DoesNotBlankLocal() throws {
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        try placemarks.setBackend(localID: local.id, backendID: "pmbackend00001", owner: nil)
        try placemarks.upsert(remotePlacemark(id: "pmbackend00001", withPlace: false))

        let row = try XCTUnwrap(placemarks.fetchById(local.id))
        XCTAssertEqual(row.place, place)
        XCTAssertEqual(try placemarks.count(), 1, "merged onto the local row, no duplicate")
    }

    func testPollEnrichment_OfflineSample_GetsPlacemarkAndFeatures() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 2, mtb: "6326")
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{}", licenseJSON: nil)
        ]
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.version, 2)
        XCTAssertNotNil(try placemarks.fetchById("pmbackend00001"))
        XCTAssertEqual(try features.count(sampleID: sample.id), 1)
    }

    // MARK: - wire format

    func testFeaturesBody_SendsPropertiesAndLicenseAsJSON() throws {
        try features.replace(sampleID: "s", features: [feature("a", license: "{\"id\":\"CC-BY\"}")])
        let body = SampleFeaturesClient.replaceBody(try features.all(sampleID: "s"))
        let items = try XCTUnwrap(body["features"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["source_id"] as? String, "wdpa")
        XCTAssertEqual((items[0]["properties"] as? [String: Any])?["name"] as? String, "a")
        XCTAssertEqual((items[0]["license"] as? [String: Any])?["id"] as? String, "CC-BY")
        XCTAssertNotNil(SampleFeaturesClient.replaceBody([])["features"], "key required even when empty")
    }

    func testResolveBody_HasFlatPlaceFieldsAndSource() {
        let body = PlacemarkClient.placeBody(place, source: .backendService)
        XCTAssertEqual(body["geocoding_source"] as? String, "backend_service")
        XCTAssertEqual(body["country_iso"] as? String, "DE")
        XCTAssertEqual(body["admin_municipality"] as? String, "Ochsenfurt")
        XCTAssertEqual(body["admin_municipality_level"] as? Int, 8)
        XCTAssertEqual(body["admin_county"] as? String, "")
    }

    // MARK: - helpers

    /// A local sample as the on-device resolver leaves it: local
    /// placemark (UUID, no backend id), status backend_service, MTB,
    /// bearing, GPS height and two features.
    private func seedResolvedSample() throws -> LocalSample {
        var sample = try store.createLocal(lat: 49.681616, lon: 10.039652, elevation: 250,
                                           collectedFrom: date(2026, 5, 19, 14))
        let pm = try placemarks.lookupOrCreate(place: place, source: .backendService)
        sample.placemark = pm.id
        sample.locationStatus = .backendService
        sample.mtbSheetNumber = "6326"
        sample.mtbSheetName = "Ochsenfurt"
        sample.mtbQuadrant = 1
        sample.bearingLabel = "Ochsenfurt"
        sample.bearingInside = true
        try store.update(sample)
        try features.replace(sampleID: sample.id, features: [feature("a"), feature("b")])
        // swiftlint:disable:next force_unwrapping
        return try store.fetchById(sample.id)!
    }

    private func seedSyncedSample(status: LocationStatus) throws -> LocalSample {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        sample.version = 2
        sample.locationStatus = status
        try store.update(sample)
        // swiftlint:disable:next force_unwrapping
        return try store.fetchById(sample.id)!
    }

    private func feature(_ id: String, license: String? = nil) -> OrtusFeature {
        OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: id,
                     propertiesJSON: "{\"name\":\"\(id)\"}", licenseJSON: license)
    }

    private func makeRunner(
        push: MockPush,
        placemarks pm: MockPlacemarks? = nil,
        features fx: MockFeatures? = nil
    ) -> SyncRunner {
        let pm = pm ?? MockPlacemarks(log: log)
        let fx = fx ?? MockFeatures(log: log)
        return SyncRunner(
            store: store,
            mutationsStore: mutations,
            placemarkStore: placemarks,
            featureStore: features,
            endpointProvider: { "http://test.invalid" },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(1),
            clientFactory: { _, _ in push },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
    }

    private func runUntilQuiescent(_ runner: SyncRunner) async {
        runner.kick()
        for _ in 0 ..< 300 {
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

    private func remote(
        id: String,
        code: String,
        clientUuid: String? = nil,
        status: String = "",
        placemark: String = "",
        elevation: Double = 0,
        elevationSource: String = "",
        version: Int = 1,
        mtb: String? = nil,
        lat: Double = 49.68,
        lon: Double = 10.04
    ) -> Sample {
        var dict: [String: Any] = [
            "id": id,
            "sample_id": code,
            "fieldtrip": "ft-1",
            "locality": "",
            "latitude": lat,
            "longitude": lon,
            "begin_date": "2026-05-19T12:00:00.000Z",
            "client_updated_at": "2026-05-19T12:00:00.000Z",
            "location_source": "location_service",
            "time_zone": "Europe/Berlin",
            "version": version,
            "elevation": elevation,
            "elevation_source": elevationSource,
            "location_status": status,
            "placemark": placemark,
            "placemark_suggestion": "",
            "mtb_sheet_number": mtb ?? "",
            "mtb_sheet_name": mtb == nil ? "" : "Ochsenfurt",
            "mtb_quadrant": mtb == nil ? 0 : 1,
            "elevation_dem": 0,
            "slope_deg": 0,
            "aspect_deg": 0,
            "aspect_compass": "",
            "terrain_flat": false,
            "bearing_label": "",
            "bearing_distance_km": 0,
            "bearing_inside": false
        ]
        if let clientUuid { dict["client_uuid"] = clientUuid }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }

    private func remotePlacemark(
        id: String,
        source: String = "backend_service",
        owner: String = "",
        withPlace: Bool = true
    ) -> Placemark {
        var dict: [String: Any] = [
            "id": id,
            "country": "DE",
            "geocoding_source": source,
            "dedup_hash": place.dedupHash,
            "owner": owner
        ]
        if withPlace {
            dict["country_iso"] = "DE"
            for tier in AdminTier.allCases {
                let value = place.admin[tier]
                dict[tier.rawValue] = value?.name ?? ""
                dict["\(tier.rawValue)_native"] = value?.native ?? ""
                dict["\(tier.rawValue)_level"] = value?.level ?? 0
            }
            dict["island"] = ""
            dict["mountain_range"] = ""
            dict["mountain"] = ""
        }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.fieldworks.decode(Placemark.self, from: data)
    }
}

// MARK: - Mocks

private final class CallLog: @unchecked Sendable {
    var calls: [String] = []
}

private final class MockPush: SamplePushClient, @unchecked Sendable {
    let log: CallLog
    var createResponse: Sample?
    var updateResponse: Sample?
    var fetchResponse: Sample?
    var lastCreate: SampleCreateInput?
    var lastUpdate: SampleUpdateInput?
    var duringCreate: (@MainActor () -> Void)?
    var duringFetch: (@MainActor () -> Void)?

    init(log: CallLog) { self.log = log }

    func createSample(_ input: SampleCreateInput) async throws -> Sample {
        log.calls.append("create")
        lastCreate = input
        if let duringCreate { await duringCreate() }
        guard let createResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return createResponse
    }

    func updateSample(id _: String, input: SampleUpdateInput) async throws -> Sample {
        log.calls.append("update")
        lastUpdate = input
        guard let updateResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return updateResponse
    }

    func fetchSample(id _: String) async throws -> Sample {
        if let duringFetch { await duringFetch() }
        guard let response = fetchResponse ?? createResponse else {
            throw SampleClientError.http(status: 404, body: "")
        }
        return response
    }
}

private final class MockPlacemarks: PlacemarkSyncClient, @unchecked Sendable {
    let log: CallLog
    var resolveResponse: Placemark?
    var fetchResponse: [Placemark] = []
    var resolved: [(place: Place, source: Placemark.GeocodingSource)] = []
    var fetchedIDs: [[String]] = []

    init(log: CallLog) { self.log = log }

    func resolve(place: Place, source: Placemark.GeocodingSource) async throws -> Placemark {
        log.calls.append("resolve")
        resolved.append((place, source))
        guard let resolveResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return resolveResponse
    }

    func fetchMany(ids: [String]) async throws -> [Placemark] {
        fetchedIDs.append(ids)
        return fetchResponse.filter { ids.contains($0.id) }
    }
}

private final class MockFeatures: SampleFeaturesSyncClient, @unchecked Sendable {
    let log: CallLog
    var replaceError: Error?
    var fetchResponse: [RemoteSampleFeature] = []
    var replaced: [(sampleBackendID: String, features: [LocalSampleFeature])] = []
    var fetchedIDs: [[String]] = []

    init(log: CallLog) { self.log = log }

    func replaceFeatures(sampleBackendID: String, features: [LocalSampleFeature]) async throws {
        log.calls.append("features")
        if let replaceError { throw replaceError }
        replaced.append((sampleBackendID, features))
    }

    func fetchFeatures(sampleBackendIDs: [String]) async throws -> [RemoteSampleFeature] {
        fetchedIDs.append(sampleBackendIDs)
        return fetchResponse.filter { sampleBackendIDs.contains($0.sample) }
    }
}

private final class MockList: SampleListClient, @unchecked Sendable {
    var items: [Sample] = []
    func listRecent(limit _: Int) async throws -> [Sample] { items }
}
