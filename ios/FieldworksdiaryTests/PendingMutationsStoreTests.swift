@testable import Fieldworksdiary
import XCTest

@MainActor
final class PendingMutationsStoreTests: XCTestCase {
    private var database: Database!
    private var store: PendingMutationsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try super.tearDownWithError()
    }

    func testEnqueueAndFetchSingle() throws {
        let payload = #"{"latitude":49.79,"longitude":9.94}"#.data(using: .utf8)!
        _ = try store.enqueue(
            entityType: .sample,
            entityId: nil,
            op: .create,
            payload: payload
        )

        let all = try store.fetch(entityType: .sample)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].entityType, .sample)
        XCTAssertEqual(all[0].op, .create)
        XCTAssertEqual(all[0].attempts, 0)
        XCTAssertNil(all[0].lastError)
    }

    func testDequeueRemovesRow() throws {
        let m = try store.enqueue(
            entityType: .sample, entityId: nil, op: .create,
            payload: Data()
        )
        try store.dequeue(m.id)
        XCTAssertEqual(try store.count(), 0)
    }

    func testFailureIncrementsAttemptsAndKeepsRow() throws {
        let m = try store.enqueue(
            entityType: .sample, entityId: nil, op: .create,
            payload: Data()
        )
        try store.recordFailure(m.id, error: "HTTP 500")
        try store.recordFailure(m.id, error: "timeout")

        let reloaded = try XCTUnwrap(try store.fetch(entityType: .sample).first)
        XCTAssertEqual(reloaded.attempts, 2)
        XCTAssertEqual(reloaded.lastError, "timeout")
        XCTAssertNotNil(reloaded.lastAttemptAt)
    }

    func testFetchAllOrderedRespectsFKOrder() throws {
        // Enqueue in *reverse* FK-order on purpose — the store has to
        // re-order to Placemark → Locality → Fieldtrip → Sample →
        // SamplePhoto → Determination regardless of insert order.
        _ = try store.enqueue(entityType: .determination, entityId: "d", op: .create, payload: Data())
        _ = try store.enqueue(entityType: .samplePhoto, entityId: "p", op: .create, payload: Data())
        _ = try store.enqueue(entityType: .sample, entityId: "s", op: .create, payload: Data())
        _ = try store.enqueue(entityType: .fieldtrip, entityId: "f", op: .create, payload: Data())
        _ = try store.enqueue(entityType: .locality, entityId: "l", op: .create, payload: Data())
        _ = try store.enqueue(entityType: .placemark, entityId: "pm", op: .create, payload: Data())

        let ordered = try store.fetchAllOrdered()
        XCTAssertEqual(ordered.map(\.entityType), [
            .placemark, .locality, .fieldtrip, .sample, .samplePhoto, .determination,
        ])
    }

    func testFetchAllOrderedSecondaryByCreatedAt() throws {
        // Two samples — older one should win the within-bucket order.
        let older = try store.enqueue(entityType: .sample, entityId: nil, op: .create, payload: Data())
        // Tiny sleep so created_at is monotone (the test relies on
        // GRDB's wall-clock granularity, not on UUID order).
        try Thread.sleep(forTimeInterval: 0.01) // swiftlint:disable:this force_try
        let newer = try store.enqueue(entityType: .sample, entityId: nil, op: .create, payload: Data())

        let ordered = try store.fetchAllOrdered()
        XCTAssertEqual(ordered.first?.id, older.id, "oldest first within bucket")
        XCTAssertEqual(ordered.last?.id, newer.id)
    }

    func testUpdatePayloadAndEntityId() throws {
        let m = try store.enqueue(
            entityType: .sample, entityId: nil, op: .create,
            payload: Data("v1".utf8)
        )
        try store.updatePayload(m.id, payload: Data("v2".utf8), entityId: "backend-1")

        let reloaded = try XCTUnwrap(try store.fetch(entityType: .sample).first)
        XCTAssertEqual(reloaded.payloadJson, Data("v2".utf8))
        XCTAssertEqual(reloaded.entityId, "backend-1")
    }

    func testResetClearsTable() throws {
        _ = try store.enqueue(entityType: .sample, entityId: nil, op: .create, payload: Data())
        _ = try store.enqueue(entityType: .fieldtrip, entityId: nil, op: .create, payload: Data())
        XCTAssertEqual(try store.count(), 2)
        try store.reset()
        XCTAssertEqual(try store.count(), 0)
    }
}
