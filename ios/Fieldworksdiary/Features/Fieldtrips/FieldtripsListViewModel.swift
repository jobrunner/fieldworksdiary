import Foundation

@MainActor
final class FieldtripsListViewModel: ObservableObject {
    /// All fieldtrips currently in the local store (un-filtered).
    @Published private(set) var all: [LocalFieldtrip] = []
    /// View-visible list after applying the in-memory filter.
    @Published private(set) var visible: [LocalFieldtrip] = []
    @Published private(set) var isHydrating = false
    @Published private(set) var hydratingError: String?

    @Published var filter: FieldtripsFilter = .none {
        didSet { rebuildVisible() }
    }

    private let store: LocalFieldtripStore
    private let hydrator: FieldtripsHydrator
    private var observationTask: Task<Void, Never>?

    init(store: LocalFieldtripStore, hydrator: FieldtripsHydrator) {
        self.store = store
        self.hydrator = hydrator
    }

    deinit { observationTask?.cancel() }

    func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await items in self.store.observeAll() {
                self.all = items
                self.rebuildVisible()
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

    /// Unique countries that appear in `all`, sorted alphabetically.
    /// Drives the Region picker on the filter sheet.
    var knownCountries: [String] {
        Array(Set(all.compactMap { $0.country?.nilIfEmpty })).sorted()
    }

    private func rebuildVisible() {
        visible = filter.isActive ? filter.apply(to: all) : all
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
