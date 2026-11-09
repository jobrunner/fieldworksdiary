@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Store methods behind the place UI (Phase O2, Task 17): accept /
/// dismiss a backend suggestion, manual height, coordinate correction
/// on a manual sample, and resending a failed sample. Each one writes
/// only its own columns and queues an outbox update for pushed rows.
@MainActor
final class SampleLocationEditsTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var placemarks: LocalPlacemarkStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)
        placemarks = LocalPlacemarkStore(database: database)
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        placemarks = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - suggestion

    func testAcceptSuggestion_TakesSuggestionAsBackendServicePlace() throws {
        let sample = try seedManualWithSuggestion()
        try store.acceptPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmsuggestion01")
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertEqual(stored.locationStatus, .backendService)
        let queued = try XCTUnwrap(mutations.fetch(entityType: .sample).first)
        XCTAssertEqual(queued.op, .update)
        XCTAssertTrue(SampleUpdatePayload.decode(queued.payloadJson).clearsSuggestion)
    }

    func testDismissSuggestion_KeepsManualPlaceAndQueuesExplicitClear() throws {
        let sample = try seedManualWithSuggestion()
        try store.dismissPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmmanual000001")
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertEqual(stored.locationStatus, .manual)
        let queued = try XCTUnwrap(mutations.fetch(entityType: .sample).first)
        XCTAssertTrue(SampleUpdatePayload.decode(queued.payloadJson).clearsSuggestion)
    }

    func testAcceptSuggestion_WithoutSuggestionIsNoOp() throws {
        var sample = try seedManualWithSuggestion()
        sample.placemarkSuggestion = nil
        try store.update(sample)
        try store.acceptPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)
        XCTAssertEqual(try store.fetchById(sample.id)?.placemark, "pmmanual000001")
        XCTAssertEqual(try mutations.count(), 0)
    }

    // MARK: - elevation

    func testSetManualElevation() throws {
        let sample = try seedPushed(status: .backendService)
        try store.setManualElevation(id: sample.id, elevation: 412, mutationsStore: mutations)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.elevation, 412)
        XCTAssertEqual(stored.elevationSource, .manual)
        XCTAssertNil(stored.verticalAccuracy, "a typed height has no measured accuracy")
        XCTAssertEqual(try mutations.count(), 1)
    }

    // MARK: - coordinate correction on a manual sample

    func testUpdateCoordinate_ManualRetake_DropsManualPlaceAndGoesPending() throws {
        let sample = try seedManualWithSuggestion()
        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0,
                                   keepManualPlace: false, mutationsStore: mutations)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertNil(stored.placemark)
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertEqual(stored.locationStatus, .pending)
        XCTAssertEqual(stored.locationSource, LocationSource.user.rawValue)
        let queued = try XCTUnwrap(mutations.fetch(entityType: .sample).first)
        XCTAssertTrue(SampleUpdatePayload.decode(queued.payloadJson).coordinateChanged)
    }

    func testUpdateCoordinate_ManualKeep_KeepsManualPlace() throws {
        let sample = try seedManualWithSuggestion()
        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0,
                                   keepManualPlace: true, mutationsStore: mutations)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmmanual000001")
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertEqual(stored.locationStatus, .manual)
    }

    // MARK: - resend

    func testResendFailed_PushedRowAfterGivingUp_RequeuesUpdate() throws {
        let sample = try seedPushed(status: .backendService)
        try store.setSyncState(id: sample.id, status: .failed, error: "Konflikt")
        XCTAssertEqual(try mutations.count(), 0, "the runner dropped the mutation after 3 passes")

        try store.resendFailed(id: sample.id, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.syncStatus, .pending)
        XCTAssertNil(stored.syncError)
        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.op, .update)
        XCTAssertEqual(queued.first?.entityId, sample.id)
    }

    func testResendFailed_WithQueuedMutation_DoesNotDuplicate() throws {
        let sample = try seedPushed(status: .backendService)
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update, payload: Data())
        try store.setSyncState(id: sample.id, status: .failed, error: "Versionskonflikt – wird erneut versucht.")

        try store.resendFailed(id: sample.id, mutationsStore: mutations)

        XCTAssertEqual(try mutations.count(), 1)
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .pending)
    }

    func testResendFailed_UnpushedRowWithoutCreate_RequeuesCreate() throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04)
        try store.setSyncState(id: sample.id, status: .failed, error: "HTTP 500")

        try store.resendFailed(id: sample.id, mutationsStore: mutations)

        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.op, .create)
        XCTAssertEqual(queued.first?.entityId, sample.id)
    }

    func testResendFailed_NotFailedIsNoOp() throws {
        let sample = try seedPushed(status: .backendService)
        try store.resendFailed(id: sample.id, mutationsStore: mutations)
        XCTAssertEqual(try mutations.count(), 0)
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
    }

    // MARK: - helpers

    private func seedPushed(status: LocationStatus) throws -> LocalSample {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, elevation: 250)
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        sample.version = 2
        sample.locationStatus = status
        sample.verticalAccuracy = 5
        try store.update(sample)
        return try XCTUnwrap(store.fetchById(sample.id))
    }

    private func seedManualWithSuggestion() throws -> LocalSample {
        var sample = try seedPushed(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = "pmsuggestion01"
        try store.update(sample)
        return try XCTUnwrap(store.fetchById(sample.id))
    }
}
