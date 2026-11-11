import FieldworksGeo
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

    /// Places of the local samples per fieldtrip id (Land/Ort filter).
    @Published private(set) var placeIndex: [String: [Place]] = [:]

    /// Place line per fieldtrip id, derived from its samples.
    @Published private(set) var placeSummaries: [String: FieldtripPlaceSummary] = [:]

    private let store: LocalFieldtripStore
    private let hydrator: FieldtripsHydrator
    private let samples: LocalSampleStore?
    private let placemarks: LocalPlacemarkStore?
    private var observationTask: Task<Void, Never>?
    private var placesObservationTask: Task<Void, Never>?

    init(
        store: LocalFieldtripStore,
        hydrator: FieldtripsHydrator,
        samples: LocalSampleStore? = nil,
        placemarks: LocalPlacemarkStore? = nil
    ) {
        self.store = store
        self.hydrator = hydrator
        self.samples = samples
        self.placemarks = placemarks
    }

    deinit {
        observationTask?.cancel()
        placesObservationTask?.cancel()
    }

    func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await items in self.store.observeAll() {
                self.all = items
                self.rebuildVisible()
            }
        }
        // Place lines follow every sample/placemark write, e.g. the
        // samples hydration after a reinstall, which runs outside this
        // screen's refresh.
        placesObservationTask?.cancel()
        if let samples, placemarks != nil {
            placesObservationTask = Task { [weak self] in
                for await snapshot in samples.observeWithPlacemarks() {
                    guard let self else { return }
                    self.applyPlaces(samples: snapshot.samples, placemarks: snapshot.placemarks)
                }
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        isHydrating = true
        defer { isHydrating = false }
        await hydrator.pull()
        hydratingError = hydrator.lastError
        reloadPlaces()
    }

    /// Re-reads the samples' places (cheap: two local reads) and
    /// re-applies the filter.
    func reloadPlaces() {
        guard let samples, let placemarks else {
            rebuildVisible()
            return
        }
        applyPlaces(
            samples: (try? samples.fetchAll()) ?? [],
            placemarks: (try? placemarks.fetchAllByID()) ?? [:]
        )
    }

    private func applyPlaces(samples all: [LocalSample], placemarks cached: [String: LocalPlacemark]) {
        placeIndex = FieldtripsFilter.placeIndex(
            samples: all.map { (fieldtrip: $0.fieldtrip, placemark: $0.placemark) },
            placemarks: cached
        )
        placeSummaries = FieldtripPlaceSummary.index(samples: all, placemarks: cached)
        rebuildVisible()
    }

    /// ISO codes of the countries the local samples' places are in.
    /// Drives the „Land“ picker on the filter sheet.
    var knownCountries: [String] {
        FieldtripsFilter.countries(in: placeIndex)
    }

    private func rebuildVisible() {
        visible = filter.isActive ? filter.apply(to: all, places: placeIndex) : all
    }
}
