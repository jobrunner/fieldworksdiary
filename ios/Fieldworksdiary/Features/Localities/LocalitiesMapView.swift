import SwiftUI
import MapKit

/// Map of every locality the local store knows about. Pins are
/// clickable — tap navigates into the locality detail. Radius shows
/// as a tinted circle so the user can see how generous a given
/// locality is at a glance.
struct LocalitiesMapView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        LocalitiesMapScreen(store: container.localitiesStore)
    }
}

private struct LocalitiesMapScreen: View {
    @StateObject private var viewModel: LocalitiesMapViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedID: String?
    @State private var navigationID: String?

    init(store: LocalLocalityStore) {
        _viewModel = StateObject(wrappedValue: LocalitiesMapViewModel(store: store))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            if !viewModel.items.isEmpty {
                countChip
            } else {
                emptyOverlay
            }
        }
        .navigationTitle("Fundorte (Karte)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.start()
            updateCameraToFit()
        }
        .onChange(of: viewModel.items) { _, _ in updateCameraToFit() }
        .onChange(of: selectedID) { _, newValue in
            if let newValue {
                navigationID = newValue
                // Reset the map selection so the same pin can be
                // re-tapped after returning from the detail.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    selectedID = nil
                }
            }
        }
        .navigationDestination(item: $navigationID) { id in
            LocalityDetailView(localityID: id)
        }
    }

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedID) {
            ForEach(viewModel.items) { l in
                if let coord = l.coordinate {
                    Marker(l.displayName, coordinate: coord)
                        .tag(l.id)
                    if let radius = l.radiusM, radius > 0 {
                        MapCircle(center: coord, radius: radius)
                            .foregroundStyle(.red.opacity(0.15))
                            .stroke(.red.opacity(0.6), lineWidth: 1)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    private var countChip: some View {
        Text("\(viewModel.items.count) Fundort\(viewModel.items.count == 1 ? "" : "e")")
            .font(.footnote)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
    }

    private var emptyOverlay: some View {
        ContentUnavailableView {
            Label("Keine Fundorte", systemImage: "mappin.slash")
        } description: {
            Text("Lege Fundorte in der Liste an — sie erscheinen hier sofort.")
        }
        .background(.regularMaterial)
    }

    private func updateCameraToFit() {
        let coords = viewModel.items.compactMap { $0.coordinate }
        guard !coords.isEmpty else {
            cameraPosition = .region(.germany)
            return
        }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        // 1.5× padding around the bounding box, but never tighter
        // than a 1-km diagonal — otherwise the single-pin case looks
        // like the map is broken at street zoom.
        let latDelta = max(0.01, (lats.max()! - lats.min()!) * 1.5)
        let lonDelta = max(0.01, (lons.max()! - lons.min()!) * 1.5)
        cameraPosition = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        ))
    }
}

@MainActor
private final class LocalitiesMapViewModel: ObservableObject {
    @Published private(set) var items: [LocalLocality] = []

    private let store: LocalLocalityStore
    private var task: Task<Void, Never>?

    init(store: LocalLocalityStore) { self.store = store }

    deinit { task?.cancel() }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            for await all in self.store.observeAll() {
                self.items = all.filter { $0.coordinate != nil }
            }
        }
    }
}

private extension LocalLocality {
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = centroidLat, let lon = centroidLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var displayName: String { name.isEmpty ? "(ohne Namen)" : name }
}

private extension MKCoordinateRegion {
    static var germany: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51, longitude: 10),
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
        )
    }
}
