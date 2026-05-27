import MapKit
import SwiftUI

/// Map of every locality the local store knows about, plus the
/// individual samples as a secondary layer (R8e). Annotations cluster
/// on zoom-out (native MapKit clustering via `clusteringIdentifier`)
/// and split into single pins on zoom-in. Tapping a locality pin
/// navigates into its detail; tapping a cluster zooms in.
struct LocalitiesMapView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        LocalitiesMapScreen(
            localitiesStore: container.localitiesStore,
            sampleStore: container.store
        )
    }
}

private struct LocalitiesMapScreen: View {
    @StateObject private var viewModel: LocalitiesMapViewModel
    @State private var navigationID: String?

    init(localitiesStore: LocalLocalityStore, sampleStore: LocalSampleStore) {
        _viewModel = StateObject(wrappedValue: LocalitiesMapViewModel(
            localitiesStore: localitiesStore,
            sampleStore: sampleStore
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ClusteredLocalitiesMap(
                localities: viewModel.localities,
                samples: viewModel.samples,
                onSelectLocality: { navigationID = $0 }
            )
            .ignoresSafeArea(edges: .bottom)

            if !viewModel.localities.isEmpty || !viewModel.samples.isEmpty {
                countChip
            } else {
                emptyOverlay
            }
        }
        .navigationTitle("Fundorte (Karte)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start() }
        .navigationDestination(item: $navigationID) { id in
            LocalityDetailView(localityID: id)
        }
    }

    private var countChip: some View {
        Text("\(viewModel.localities.count) Fundort\(viewModel.localities.count == 1 ? "" : "e") · \(viewModel.samples.count) Proben")
            .font(AppFont.caption)
            .padding(.vertical, AppSpacing.xs)
            .padding(.horizontal, AppSpacing.md)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, AppSpacing.lg)
    }

    private var emptyOverlay: some View {
        ContentUnavailableView {
            Label("Keine Fundorte", systemImage: "mappin.slash")
        } description: {
            Text("Lege Fundorte in der Liste an — sie erscheinen hier sofort.")
        }
        .background(.regularMaterial)
    }
}

// MARK: - View model

@MainActor
private final class LocalitiesMapViewModel: ObservableObject {
    @Published private(set) var localities: [LocalLocality] = []
    @Published private(set) var samples: [LocalSample] = []

    private let localitiesStore: LocalLocalityStore
    private let sampleStore: LocalSampleStore
    private var localitiesTask: Task<Void, Never>?
    private var samplesTask: Task<Void, Never>?

    init(localitiesStore: LocalLocalityStore, sampleStore: LocalSampleStore) {
        self.localitiesStore = localitiesStore
        self.sampleStore = sampleStore
    }

    deinit {
        localitiesTask?.cancel()
        samplesTask?.cancel()
    }

    func start() {
        localitiesTask?.cancel()
        localitiesTask = Task { [weak self] in
            guard let self else { return }
            for await all in self.localitiesStore.observeAll() {
                self.localities = all.filter { $0.mapCoordinate != nil }
            }
        }
        samplesTask?.cancel()
        samplesTask = Task { [weak self] in
            guard let self else { return }
            for await all in self.sampleStore.observeAll() {
                self.samples = all.filter { $0.mapCoordinate != nil }
            }
        }
    }
}

// MARK: - Annotations

private final class LocalityAnnotation: NSObject, MKAnnotation {
    let id: String
    let title: String?
    let coordinate: CLLocationCoordinate2D
    let radius: Double?

    init(id: String, title: String, coordinate: CLLocationCoordinate2D, radius: Double?) {
        self.id = id
        self.title = title
        self.coordinate = coordinate
        self.radius = radius
    }
}

private final class SampleAnnotation: NSObject, MKAnnotation {
    let id: String
    let title: String?
    let coordinate: CLLocationCoordinate2D

    init(id: String, title: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.title = title
        self.coordinate = coordinate
    }
}

// MARK: - Clustered MKMapView bridge

private struct ClusteredLocalitiesMap: UIViewRepresentable {
    let localities: [LocalLocality]
    let samples: [LocalSample]
    let onSelectLocality: (String) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(map: map, localities: localities, samples: samples)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectLocality: onSelectLocality)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let onSelectLocality: (String) -> Void
        private var didFit = false

        init(onSelectLocality: @escaping (String) -> Void) {
            self.onSelectLocality = onSelectLocality
        }

        func sync(map: MKMapView, localities: [LocalLocality], samples: [LocalSample]) {
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            map.removeOverlays(map.overlays)

            var annotations: [MKAnnotation] = []
            for loc in localities {
                guard let coord = loc.mapCoordinate else { continue }
                annotations.append(LocalityAnnotation(
                    id: loc.id, title: loc.mapDisplayName, coordinate: coord, radius: loc.radiusM
                ))
                if let radius = loc.radiusM, radius > 0 {
                    map.addOverlay(MKCircle(center: coord, radius: radius))
                }
            }
            for sample in samples {
                guard let coord = sample.mapCoordinate else { continue }
                annotations.append(SampleAnnotation(
                    id: sample.id, title: sample.sampleID, coordinate: coord
                ))
            }
            map.addAnnotations(annotations)

            // Fit once, on the first non-empty render.
            if !didFit, !annotations.isEmpty {
                map.showAnnotations(annotations, animated: false)
                didFit = true
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "cluster", for: cluster
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "cluster")
                view.annotation = cluster
                // A cluster that contains any locality reads as a
                // locality cluster (brand colour); pure-sample clusters
                // stay muted.
                let hasLocality = cluster.memberAnnotations.contains { $0 is LocalityAnnotation }
                view.markerTintColor = hasLocality ? UIColor(AppColor.brandPrimary) : .secondaryLabel
                return view
            }

            switch annotation {
            case let loc as LocalityAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "locality", for: loc
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: loc, reuseIdentifier: "locality")
                view.annotation = loc
                view.clusteringIdentifier = "fwd"
                view.canShowCallout = true
                view.markerTintColor = UIColor(AppColor.brandPrimary)
                view.glyphImage = UIImage(systemName: "mappin")
                view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
                view.displayPriority = .required
                return view
            case let sample as SampleAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "sample", for: sample
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: sample, reuseIdentifier: "sample")
                view.annotation = sample
                view.clusteringIdentifier = "fwd"
                view.markerTintColor = .secondaryLabel
                view.glyphImage = UIImage(systemName: "leaf")
                view.displayPriority = .defaultLow
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            switch view.annotation {
            case let cluster as MKClusterAnnotation:
                // Zoom into the cluster's bounding region.
                mapView.deselectAnnotation(cluster, animated: false)
                let region = MKCoordinateRegion(
                    center: cluster.coordinate,
                    span: zoomedSpan(mapView.region.span)
                )
                mapView.setRegion(region, animated: true)
            case let loc as LocalityAnnotation:
                mapView.deselectAnnotation(loc, animated: false)
                onSelectLocality(loc.id)
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, annotationView: MKAnnotationView, calloutAccessoryControlTapped _: UIControl) {
            if let loc = annotationView.annotation as? LocalityAnnotation {
                onSelectLocality(loc.id)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.15)
            renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.6)
            renderer.lineWidth = 1
            return renderer
        }

        private func zoomedSpan(_ span: MKCoordinateSpan) -> MKCoordinateSpan {
            MKCoordinateSpan(
                latitudeDelta: max(0.002, span.latitudeDelta / 4),
                longitudeDelta: max(0.002, span.longitudeDelta / 4)
            )
        }
    }
}

// MARK: - Coordinate helpers

private extension LocalLocality {
    var mapCoordinate: CLLocationCoordinate2D? {
        guard let lat = latitude ?? centroidLat, let lon = longitude ?? centroidLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var mapDisplayName: String {
        name.isEmpty ? "(ohne Namen)" : name
    }
}

private extension LocalSample {
    var mapCoordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
