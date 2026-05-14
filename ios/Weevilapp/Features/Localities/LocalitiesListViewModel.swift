import Foundation

@MainActor
final class LocalitiesListViewModel: ObservableObject {
    @Published private(set) var localities: [LocalLocality] = []
    @Published private(set) var isHydrating = false
    @Published private(set) var hydratingError: String?

    private let store: LocalLocalityStore
    private let hydrator: LocalitiesHydrator
    private var observationTask: Task<Void, Never>?

    init(store: LocalLocalityStore, hydrator: LocalitiesHydrator) {
        self.store = store
        self.hydrator = hydrator
    }

    deinit { observationTask?.cancel() }

    func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await items in self.store.observeAll() {
                self.localities = items
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        isHydrating = true
        defer { isHydrating = false }
        await hydrator.pull()
        hydratingError = hydrator.lastError
    }
}
