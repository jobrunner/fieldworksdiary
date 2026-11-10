import FliptClient
import Foundation

/// Auswertung von Feature-Flags. Abstraktion über dem Flipt-SDK, damit
/// Tests einen Fake einhängen können. Implementierungen dürfen nie
/// werfen: jeder Fehler wird zu `false` bzw. leerer Liste.
protocol FeatureFlagEvaluating: Sendable {
    func isEnabled(_ key: String, entityID: String, context: [String: String]) -> Bool
    func flagKeys() -> [String]
}

/// Adapter auf den Flipt-Client (clientseitige Auswertung, Polling
/// alle 120 s im SDK). Der Snapshot kommt öffentlich von
/// `<url>/internal/v1/evaluation/snapshot/namespace/default`.
final class FliptFlagEvaluator: FeatureFlagEvaluating, @unchecked Sendable {
    private let client: FliptClient
    private let lock = NSLock()

    /// Baut den Client und holt den ersten Snapshot — blockiert (Netz),
    /// darum nur abseits des Main-Threads aufrufen. Wirft, wenn der
    /// Client keinen Zustand liefern kann.
    static func make(url: String) throws -> FliptFlagEvaluator {
        let client = try FliptClient(
            environment: "default",
            namespace: "default",
            url: url,
            updateInterval: .seconds(120),
            fetchMode: .polling,
            errorStrategy: .fallback
        )
        // Probe: ein kaputter Engine-Zustand fällt hier auf, nicht erst
        // bei der ersten Auswertung im UI.
        _ = try client.listFlags()
        return FliptFlagEvaluator(client: client)
    }

    private init(client: FliptClient) {
        self.client = client
    }

    func isEnabled(_ key: String, entityID: String, context: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try client.evaluateBoolean(flagKey: key, entityID: entityID, evalContext: context).enabled
        } catch {
            Log.app.warning("feature flag evaluation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func flagKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try client.listFlags().map(\.key).sorted()
        } catch {
            Log.app.warning("feature flag listing failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Zugriff der App auf Feature-Flags. `isEnabled` blockiert nie auf
/// Netz und liefert `false`, solange kein Client geladen ist (kein
/// Netz beim Start, Fehler, leere URL).
@MainActor
final class FeatureFlags: ObservableObject {
    typealias EvaluatorFactory = @Sendable (String) throws -> FeatureFlagEvaluating

    /// Entity-ID, solange niemand angemeldet ist.
    nonisolated static let anonymousEntityID = "anonymous"

    @Published private(set) var evaluator: FeatureFlagEvaluating?

    private let entityIDProvider: () -> String?
    private let context: [String: String]

    init(evaluator: FeatureFlagEvaluating? = nil,
         entityIDProvider: @escaping () -> String?,
         context: [String: String] = FeatureFlags.defaultContext())
    {
        self.evaluator = evaluator
        self.entityIDProvider = entityIDProvider
        self.context = context
    }

    nonisolated static func defaultContext(bundle: Bundle = .main) -> [String: String] {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return ["platform": "ios", "app_version": version]
    }

    /// Baut den Client im Hintergrund. Fehler werden geloggt, die Flags
    /// bleiben dann `false`.
    func start(url: String,
               factory: @escaping EvaluatorFactory = { try FliptFlagEvaluator.make(url: $0) })
    {
        guard !url.isEmpty, evaluator == nil else { return }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let built = try factory(url)
                await self?.install(built)
            } catch {
                Log.app.warning("feature flags unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func install(_ built: FeatureFlagEvaluating) {
        evaluator = built
    }

    func isEnabled(_ key: String) -> Bool {
        guard let evaluator else { return false }
        return evaluator.isEnabled(key, entityID: entityID, context: context)
    }

    /// Geladene Flag-Keys mit aktuellem Wert (Debug-Anzeige).
    func debugSnapshot() -> [(key: String, enabled: Bool)] {
        guard let evaluator else { return [] }
        return evaluator.flagKeys().map { ($0, isEnabled($0)) }
    }

    private var entityID: String {
        let id = entityIDProvider() ?? ""
        return id.isEmpty ? Self.anonymousEntityID : id
    }
}
