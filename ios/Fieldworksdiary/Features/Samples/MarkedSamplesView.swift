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
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(sample.backendCode ?? sample.sampleID)
                .font(.body.monospaced().weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                if let locality = sample.adminUnitsLocality {
                    Text(locality).font(.subheadline)
                }
                if !sample.notes.isEmpty {
                    Text(sample.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Markierte Probe \(sample.backendCode ?? sample.sampleID)")
    }

    private func reload() {
        samples = (try? container.store.fetchMarked()) ?? []
    }
}
