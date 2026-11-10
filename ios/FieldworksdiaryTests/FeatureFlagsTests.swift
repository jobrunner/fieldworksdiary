@testable import Fieldworksdiary
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

    func testFactoryFailureKeepsFalse() async throws {
        struct Boom: Error {}
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        flags.start(url: "https://example.invalid", factory: { _ in throw Boom() })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(flags.isEnabled("x"))
    }

    func testFactorySuccessInstallsEvaluator() async throws {
        let fake = FakeEvaluator(enabledKeys: ["x"])
        let flags = FeatureFlags(entityIDProvider: { "u1" })
        flags.start(url: "https://example.invalid", factory: { _ in fake })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(flags.isEnabled("x"))
        XCTAssertEqual(flags.debugSnapshot().map(\.key), ["x"])
    }
}
