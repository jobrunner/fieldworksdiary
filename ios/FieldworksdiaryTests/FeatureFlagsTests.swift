@testable import Fieldworksdiary
import FliptClient
import XCTest

private final class FakeEvaluator: FeatureFlagEvaluating, @unchecked Sendable {
    struct Call: Equatable {
        let key: String
        let entityID: String
        let context: [String: String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    let enabledKeys: Set<String>

    init(enabledKeys: Set<String> = []) {
        self.enabledKeys = enabledKeys
    }

    func isEnabled(_ key: String, entityID: String, context: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(key: key, entityID: entityID, context: context))
        return enabledKeys.contains(key)
    }

    func flagKeys() -> [String] {
        enabledKeys.sorted()
    }
}

@MainActor
final class FeatureFlagsTests: XCTestCase {
    func testFalseWithoutClient() {
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        XCTAssertFalse(flags.isEnabled("instant-create"))
        XCTAssertTrue(flags.debugSnapshot().isEmpty)
    }

    func testPassesEntityIDAndContext() {
        let fake = FakeEvaluator(enabledKeys: ["instant-create"])
        let ctx = ["platform": "ios", "app_version": "1.2.3"]
        let flags = FeatureFlags(evaluator: fake, entityIDProvider: { "user-42" }, context: ctx)

        XCTAssertTrue(flags.isEnabled("instant-create"))
        XCTAssertFalse(flags.isEnabled("other"))
        XCTAssertEqual(fake.calls.first, .init(key: "instant-create", entityID: "user-42", context: ctx))
    }

    func testAnonymousEntityWhenLoggedOut() {
        let fake = FakeEvaluator()
        let flags = FeatureFlags(evaluator: fake, entityIDProvider: { nil })
        _ = flags.isEnabled("x")
        XCTAssertEqual(fake.calls.first?.entityID, FeatureFlags.anonymousEntityID)
    }

    func testDefaultContextHasPlatform() {
        XCTAssertEqual(FeatureFlags.defaultContext()["platform"], "ios")
        XCTAssertNotNil(FeatureFlags.defaultContext()["app_version"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFactoryFailureKeepsFalse() async {
        struct Boom: Error {}
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        let attempts = Counter()
        flags.start(url: "https://example.invalid", factory: { _ in
            _ = attempts.next()
            throw Boom()
        }, retryDelays: [])
        await waitUntil { attempts.value >= 1 }
        XCTAssertFalse(flags.isEnabled("x"))
    }

    func testFactorySuccessInstallsEvaluator() async {
        let fake = FakeEvaluator(enabledKeys: ["x"])
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        flags.start(url: "https://example.invalid", factory: { _ in fake })
        await waitUntil { flags.evaluator != nil }
        XCTAssertTrue(flags.isEnabled("x"))
        XCTAssertEqual(flags.debugSnapshot().map(\.key), ["x"])
    }

    func testRetriesAfterFailure() async {
        struct Boom: Error {}
        let attempts = Counter()
        let fake = FakeEvaluator(enabledKeys: ["x"])
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        flags.start(url: "https://example.invalid", factory: { _ in
            if attempts.next() < 2 { throw Boom() }
            return fake
        }, retryDelays: [.milliseconds(10), .milliseconds(10)])
        await waitUntil { flags.evaluator != nil }
        XCTAssertTrue(flags.isEnabled("x"))
        XCTAssertEqual(attempts.value, 2)
    }

    func testRepeatedStartBuildsOnlyOneClient() async {
        let attempts = Counter()
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        let factory: FeatureFlags.EvaluatorFactory = { _ in
            _ = attempts.next()
            Thread.sleep(forTimeInterval: 0.1)
            return FakeEvaluator()
        }
        flags.start(url: "https://example.invalid", factory: factory)
        flags.start(url: "https://example.invalid", factory: factory)
        await waitUntil { flags.evaluator != nil }
        flags.start(url: "https://example.invalid", factory: factory)
        XCTAssertEqual(attempts.value, 1)
    }

    /// Echter Client ohne Fake: Kaltstart ohne Netz darf weder abstürzen
    /// noch hängen. Läuft die Auswertung durch, ist der nil-Engine-Pfad
    /// des SDK unkritisch.
    func testRealClientOfflineDoesNotCrash() throws {
        let client = try FliptClient(
            url: "http://127.0.0.1:9",
            requestTimeout: .seconds(2),
            errorStrategy: .fallback
        )
        _ = try? client.evaluateBoolean(flagKey: "x", entityID: "u1", evalContext: [:])
        _ = try? client.listFlags()
        client.close()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// Returns the number of earlier calls.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count - 1 }
}
