@testable import Legulus
import XCTest

/// Die lokalen Daten gehören zum Konto: Abmelden löscht nichts, ein
/// anderes Konto sieht und synct nur seine eigenen Daten.
@MainActor
final class AccountSwitchTests: XCTestCase {
    private var root: URL!
    private let accountA = "usera0000000001"
    private let accountB = "userb0000000002"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("account-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testSignedOutContainerHasNoAccount() {
        let container = AppContainer(storageRoot: root)
        XCTAssertNil(container.accountID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts").path))
    }

    /// The scenario from the field: A's unsynced samples lie on the
    /// device, B signs in. B must not see or push them, and A finds
    /// them again.
    func testEachAccountKeepsItsOwnDataAcrossSignOutAndSignIn() throws {
        let container = AppContainer(storageRoot: root)
        container.switchAccount(to: accountA)
        let sample = try container.store.createLocal(lat: 49.79, lon: 9.94, notes: "von A")
        XCTAssertEqual(sample.userId, accountA)
        XCTAssertEqual(sample.syncStatus, .pending, "noch nicht hochgeladen")
        _ = try container.mutations.enqueue(entityType: .sample, entityId: nil, op: .create, payload: Data("{}".utf8))
        XCTAssertEqual(try container.mutations.count(), 1, "A hat etwas Ungesendetes")

        // A signs out: nothing is shown, nothing is deleted.
        container.switchAccount(to: nil)
        XCTAssertNil(try container.store.fetchById(sample.id))
        XCTAssertEqual(try container.mutations.count(), 0)

        // B signs in on the same device.
        container.switchAccount(to: accountB)
        XCTAssertEqual(container.accountID, accountB)
        XCTAssertNil(try container.store.fetchById(sample.id), "B sieht die Probe von A nicht")
        XCTAssertEqual(try container.mutations.count(), 0, "B hat nichts von A zu senden")
        let own = try container.store.createLocal(lat: 48.1, lon: 11.5, notes: "von B")
        XCTAssertEqual(own.userId, accountB)

        // A comes back: the unsynced sample and its outbox are there.
        container.switchAccount(to: nil)
        container.switchAccount(to: accountA)
        XCTAssertEqual(try container.store.fetchById(sample.id)?.notes, "von A")
        XCTAssertEqual(try container.store.fetchById(sample.id)?.syncStatus, .pending)
        XCTAssertEqual(try container.mutations.count(), 1)
        XCTAssertNil(try container.store.fetchById(own.id), "A sieht die Probe von B nicht")
    }

    func testDataSurvivesANewContainer() throws {
        var container: AppContainer? = AppContainer(storageRoot: root)
        container?.switchAccount(to: accountA)
        let sample = try XCTUnwrap(container?.store.createLocal(lat: 49.79, lon: 9.94, notes: "bleibt"))
        container = nil

        // App restart, signed out, then B signs in: the gap that leaked.
        let restarted = AppContainer(storageRoot: root)
        restarted.switchAccount(to: accountB)
        XCTAssertNil(try restarted.store.fetchById(sample.id))
        restarted.switchAccount(to: accountA)
        XCTAssertNotNil(try restarted.store.fetchById(sample.id))
    }

    func testSameAccountKeepsItsGraph() {
        let container = AppContainer(storageRoot: root)
        container.switchAccount(to: accountA)
        let graph = container.graph
        container.switchAccount(to: accountA)
        XCTAssertTrue(container.graph === graph)
    }

    /// The services of the account that was left stop syncing.
    func testLeavingAnAccountStopsItsSync() {
        let container = AppContainer(storageRoot: root)
        container.switchAccount(to: accountA)
        let syncOfA = container.sync
        container.switchAccount(to: accountB)
        XCTAssertFalse(container.sync === syncOfA)
        syncOfA.kick()
        XCTAssertNil(syncOfA.passTask, "kein neuer Durchlauf für das verlassene Konto")
    }

    /// At app start the signed-out placeholder is replaced by the
    /// restored account. That is no sign-out: samples waiting for a GPS
    /// fix must keep their registrations.
    func testRestoringTheAccountAtStartKeepsWaitingFixes() throws {
        let first = AppContainer(storageRoot: root)
        first.switchAccount(to: accountA)
        let sample = try first.store.createLocal(lat: nil, lon: nil, notes: "wartet auf Fix")
        first.pendingFixes.register(sampleID: sample.id, createdAt: Date())
        XCTAssertEqual(first.pendingFixes.pendingCount, 1, "Vorbedingung")

        // App restart: placeholder first, then the account is restored.
        let restarted = AppContainer(storageRoot: root)
        restarted.resumePendingFixes() // scene became active while still signed out
        restarted.switchAccount(to: accountA)
        restarted.resumePendingFixes()
        XCTAssertEqual(restarted.pendingFixes.pendingCount, 1, "die Registrierung hat den Neustart überlebt")
        restarted.pendingFixes.reset()
    }

    /// Leaving a real account does drop them: the next account must not
    /// resume fixes for samples it does not have.
    func testSigningOutDropsWaitingFixes() throws {
        let container = AppContainer(storageRoot: root)
        container.switchAccount(to: accountA)
        let sample = try container.store.createLocal(lat: nil, lon: nil, notes: "")
        container.pendingFixes.register(sampleID: sample.id, createdAt: Date())
        container.switchAccount(to: nil)
        container.switchAccount(to: accountB)
        container.resumePendingFixes()
        XCTAssertEqual(container.pendingFixes.pendingCount, 0)
    }

    /// Without storage (previews) nothing touches the disk.
    func testWithoutStorageEverythingStaysInMemory() throws {
        let container = AppContainer(storageRoot: nil)
        container.switchAccount(to: accountA)
        _ = try container.store.createLocal(lat: 49.79, lon: 9.94, notes: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts").path))
    }
}
