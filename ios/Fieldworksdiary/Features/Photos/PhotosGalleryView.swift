import SwiftUI
import UIKit

/// Cross-sample photo gallery. Three columns at default Dynamic Type;
/// `LazyVGrid` adapts down to two at larger sizes. Tapping a tile
/// pushes the parent sample's detail view.
struct PhotosGalleryView: View {
    var body: some View {
        NavigationStack {
            PhotosGalleryScreen()
        }
    }
}

struct PhotosGalleryScreen: View {
    @EnvironmentObject var container: AppContainer
    @State private var photos: [LocalPhoto] = []

    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 110

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tile, maximum: tile * 1.4), spacing: 4)]
    }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Fotos", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Fotos zu Proben tauchen automatisch hier auf, sobald du beim Anlegen einer Probe ein Bild aufnimmst.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(photos) { photo in
                            NavigationLink {
                                SampleEditorView(sampleID: photo.sampleId)
                            } label: {
                                GalleryTile(photo: photo, tile: tile)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: photo))
                        }
                    }
                    .padding(4)
                }
            }
        }
        .navigationTitle("Fotos")
        .task { reload() }
    }

    private func reload() {
        photos = (try? container.photos.fetchAll()) ?? []
    }

    private func accessibilityLabel(for photo: LocalPhoto) -> String {
        // Sample-code lookup is best-effort; if the parent sample
        // hasn't been loaded yet we just say "Foto".
        if let sample = try? container.store.fetchById(photo.sampleId) {
            return "Foto zu Probe \(sample.backendCode ?? sample.sampleID)"
        }
        return "Foto"
    }
}

/// One thumbnail in the gallery grid. Lazy-loads its JPEG to keep the
/// scroll smooth when there are dozens of tiles.
private struct GalleryTile: View {
    let photo: LocalPhoto
    let tile: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
            }
            if photo.syncStatus != .synced {
                VStack {
                    Spacer()
                    HStack(spacing: 2) {
                        Spacer()
                        Image(systemName: photo.syncStatus == .failed
                            ? "exclamationmark.triangle.fill"
                            : "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                            .padding(4)
                    }
                }
            }
        }
        .frame(width: tile, height: tile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { load() }
    }

    private func load() {
        guard image == nil else { return }
        if let data = try? PhotoStorage.readData(relativePath: photo.localPath),
           let img = UIImage(data: data)
        {
            image = img
        }
    }
}

#Preview {
    PhotosGalleryView()
        .environmentObject(AppContainer())
}
