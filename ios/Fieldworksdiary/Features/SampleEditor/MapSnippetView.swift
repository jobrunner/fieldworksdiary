import CoreLocation
import SwiftUI
import UIKit

/// Bottom-of-editor static map. Renders a cached snapshot (see
/// `MapSnapshotter`) the first time the view appears for a given
/// coordinate, then reads from cache on every subsequent view.
///
/// Tap is wired but doesn't do anything yet — Phase 14d will open a
/// full-screen interactive map view from here. We surface the action
/// label nonetheless so VoiceOver users discover it.
struct MapSnippetView: View {
    let coordinate: CLLocationCoordinate2D?
    var height: CGFloat = 160
    /// Optional tap handler — defaults to no-op so callers don't have
    /// to provide one while we wait for the full-screen map.
    var onTap: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var lastRenderedKey: String?

    var body: some View {
        Group {
            if let coordinate {
                Button(action: onTap) {
                    content(for: coordinate)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Karte")
                .accessibilityHint("Öffnet die Karte mit dem Probenort. (Detail-Ansicht folgt)")
            } else {
                placeholder
            }
        }
    }

    private func content(for coordinate: CLLocationCoordinate2D) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(.systemGray5), Color(.systemGray6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                ProgressView()
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: renderKey(for: coordinate)) {
            await load(coordinate: coordinate)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.systemGray6)
            VStack(spacing: 6) {
                Image(systemName: "map")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Karte erscheint, sobald die Position bekannt ist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Karte ist noch nicht verfügbar")
    }

    /// Cache-friendly identity for the render: when this changes,
    /// SwiftUI restarts the task and we re-fetch (or hit the cache).
    private func renderKey(for coord: CLLocationCoordinate2D) -> String {
        // 5 decimals ≈ 1.1 m of latitude — fine enough for the use
        // case, but stable while the user is tapping around small UI
        // changes that don't move the pin.
        String(format: "%.5f|%.5f|%d", coord.latitude, coord.longitude, colorScheme == .dark ? 1 : 0)
    }

    private func load(coordinate: CLLocationCoordinate2D) async {
        let key = renderKey(for: coordinate)
        if key == lastRenderedKey, image != nil { return }
        lastRenderedKey = key

        // Best-effort: 600×260 at @2x ≈ a wide phone snippet. The
        // snapshotter sizes the image in points; UIScreen.main.scale
        // is applied internally.
        let size = CGSize(width: 600, height: 260)
        do {
            let img = try await MapSnapshotter.snapshot(
                at: coordinate,
                size: size,
                span: 0.04,
                dark: colorScheme == .dark
            )
            image = img
        } catch {
            // Leave `image` as nil → the placeholder spinner stays
            // visible. We don't surface the error: a missing map
            // snippet shouldn't block the sample workflow.
            Log.persistence.error("map snapshot failed: \(error.localizedDescription)")
        }
    }
}
