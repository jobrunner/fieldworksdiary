import SwiftUI
import MapKit
import CoreLocation

/// Modal map picker. The user taps anywhere on the map to drop a pin;
/// "Übernehmen" hands the coordinate back to the caller via the
/// binding. Used as a GPS fallback (denied, no fix indoors) or to
/// correct an inaccurate auto-fix.
struct CoordinatePickerView: View {
    @Binding var selected: CLLocationCoordinate2D?
    let initialFix: CLLocation?
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition

    init(selected: Binding<CLLocationCoordinate2D?>, initialFix: CLLocation? = nil) {
        self._selected = selected
        self.initialFix = initialFix

        // Camera starts at the current GPS fix if we have one, else at
        // a sensible mainland-Europe default. The draft is seeded
        // from whatever the caller already had pinned.
        let center = selected.wrappedValue
            ?? initialFix?.coordinate
            ?? CLLocationCoordinate2D(latitude: 49.7913, longitude: 9.9534)
        self._cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )))
        self._draft = State(initialValue: selected.wrappedValue ?? initialFix?.coordinate)
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let draft {
                        Marker("Probe", coordinate: draft)
                            .tint(.red)
                    }
                    if let initialFix {
                        Annotation("GPS", coordinate: initialFix.coordinate) {
                            Image(systemName: "location.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let coord = proxy.convert(point, from: .local) {
                        draft = coord
                    }
                }
                .overlay(alignment: .bottom) {
                    coordReadout
                }
            }
            .navigationTitle("Koordinate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Übernehmen") {
                        selected = draft
                        dismiss()
                    }
                    .disabled(draft == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var coordReadout: some View {
        if let c = draft {
            VStack(spacing: 2) {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                    .font(.body.monospacedDigit())
                Text("Tippen, um Pin zu verschieben.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)
        } else {
            Text("Auf die Karte tippen, um eine Koordinate zu setzen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 16)
        }
    }
}
