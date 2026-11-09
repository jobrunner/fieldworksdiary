import SwiftUI

/// Top-level list of samples the user has starred. Same row layout as
/// `SamplesListScreen`; just a different filter.
struct MarkedSamplesView: View {
    var body: some View {
        NavigationStack {
            MarkedSamplesScreen()
        }
    }
}

struct MarkedSamplesScreen: View {
    @EnvironmentObject var container: AppContainer
    @State private var samples: [LocalSample] = []
    @State private var placemarks: [String: LocalPlacemark] = [:]

    var body: some View {
        Group {
            if samples.isEmpty {
                ContentUnavailableView {
                    Label("Noch nichts markiert", systemImage: "star")
                } description: {
                    Text("Tippe in der Proben-Detailansicht auf den Stern, um eine Probe hier zu sammeln.")
                }
            } else {
                List(samples) { sample in
                    NavigationLink {
                        SampleEditorView(sampleID: sample.id)
                    } label: {
                        row(for: sample)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Markierte Proben")
        .task { reload() }
    }

    private func row(for sample: LocalSample) -> some View {
        SampleListRow(
            code: sample.sampleID,
            placeName: PlaceDisplay.shortName(sample.placemark.flatMap { placemarks[$0] }?.place),
            notes: sample.notes,
            isMarked: true,
            hasIdConflict: sample.hasIdConflict
        )
    }

    private func reload() {
        samples = (try? container.store.fetchMarked()) ?? []
        placemarks = (try? container.placemarksStore.fetchAllByID()) ?? [:]
    }
}
