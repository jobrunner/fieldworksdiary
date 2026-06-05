@testable import Fieldworksdiary
import XCTest

/// Edit-Pfad im Store: schreibt die Row und — nur bei vorhandener
/// `backendId` — enqueued einen `.sample/.update`-Outbox-Eintrag mit
/// leerem Payload und `entityId == sample.id` (lokale UUID, wie
/// `.sample/.create`). Folge-Edits enqueuen je eine neue Mutation
/// (kein Coalesce) — der SyncRunner liest beim Replay die aktuellste
/// Row und sendet die neueste Werte.
@MainActor
final class LocalSampleStoreSaveEditsTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    func testSaveEdits_WithoutBackendId_DoesNotEnqueue() throws {
        var sample = try store.createLocal(lat: 49.79, lon: 9.94, notes: "old")
        sample.notes = "new"

        try store.saveEdits(sample, mutationsStore: mutations)

        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertTrue(updates.isEmpty, "no backend_id → no update mutation, .create picks up new value")
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.notes, "new")
    }

    func testSaveEdits_WithBackendId_EnqueuesUpdateOnLocalId() throws {
        var sample = try store.createLocal(lat: 49.79, lon: 9.94, notes: "old")
        sample.backendId = "backend-1"
        try store.update(sample)
        var fresh = try XCTUnwrap(store.fetchById(sample.id))
        fresh.notes = "edited once"

        try store.saveEdits(fresh, mutationsStore: mutations)

        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(
            updates.first?.entityId, sample.id,
            "entityId carries the *local* sample UUID — backend id is read fresh at execute time"
        )
        XCTAssertTrue(
            updates.first?.payloadJson.isEmpty ?? false,
            "payload is intentionally empty; SyncRunner reads the freshest row at PATCH time"
        )
    }

    func testSaveEdits_TwoEditsEnqueueTwoMutations_NoCoalesce() throws {
        var sample = try store.createLocal(lat: 49.79, lon: 9.94, notes: "old")
        sample.backendId = "backend-1"
        try store.update(sample)

        var first = try XCTUnwrap(store.fetchById(sample.id))
        first.notes = "first edit"
        try store.saveEdits(first, mutationsStore: mutations)

        var second = try XCTUnwrap(store.fetchById(sample.id))
        second.notes = "second edit"
        try store.saveEdits(second, mutationsStore: mutations)

        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(
            updates.count, 2,
            "no coalesce — each save enqueues its own marker; latest row state wins at PATCH time"
        )
        // The local row reflects the latest edit regardless.
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.notes, "second edit")
    }

    func testFindByCode_ExcludesGivenId() throws {
        let first = try store.createLocal(lat: 49.79, lon: 9.94)
        let second = try store.createLocal(lat: 49.80, lon: 9.95)

        // Same-day codes auto-allocate as 260605/1 + 260605/2; pick
        // `second`'s code and search excluding `first` — should only
        // find `second`.
        let hit = try store.findByCode(second.sampleID, excludingId: first.id)
        XCTAssertEqual(hit?.id, second.id)

        // Excluding `second` itself returns nothing.
        let miss = try store.findByCode(second.sampleID, excludingId: second.id)
        XCTAssertNil(miss)
    }
}
