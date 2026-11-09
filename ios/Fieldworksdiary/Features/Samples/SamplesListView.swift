import SwiftUI

/// Top-level list of every locally-known sample, grouped by
/// collecting day (newest first). New in Phase 14 — previously the
/// only way to see samples was the drill-down from a fieldtrip.
struct SamplesListView: View {
    var body: some View {
        NavigationStack {
            SamplesListScreen()
        }
    }
}

/// Internal so HomeView can embed it inside the dashboard's
/// NavigationStack without nesting a second one.
struct SamplesListScreen: View {
    @EnvironmentObject var container: AppContainer
    @State private var samples: [LocalSample] = []
    @State private var placemarks: [String: LocalPlacemark] = [:]

    var body: some View {
        Group {
            if samples.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Proben")
        .task { reload() }
    }

    private var list: some View {
        List {
            ForEach(groupedByDay(), id: \.day) { group in
                Section(group.day) {
                    ForEach(group.samples) { sample in
                        NavigationLink {
                            SampleEditorView(sampleID: sample.id)
                        } label: {
                            row(for: sample)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch keine Proben", systemImage: "tray")
        } description: {
            Text("Tippe auf das Plus auf dem Dashboard, um deine erste Probe anzulegen.")
        }
    }

    private func row(for sample: LocalSample) -> some View {
        SampleListRow(
            code: sample.backendCode ?? sample.sampleID,
            placeName: PlaceDisplay.shortName(sample.placemark.flatMap { placemarks[$0] }?.place),
            pendingPlaceText: "Ortsangaben ausstehend",
            notes: sample.notes,
            syncStatus: sample.syncStatus
        )
    }

    // MARK: - data

    private func reload() {
        samples = (try? container.store.fetchAll()) ?? []
        placemarks = (try? container.placemarksStore.fetchAllByID()) ?? [:]
    }

    private struct DayGroup {
        let day: String
        let samples: [LocalSample]
    }

    /// Buckets the samples by `collectingDay`, preserving newest-first
    /// across both axes. The header displays a localised date.
    private func groupedByDay() -> [DayGroup] {
        let buckets = Dictionary(grouping: samples, by: { $0.collectingDay })
        return buckets.keys.sorted(by: >).map { key in
            DayGroup(day: formatDay(key), samples: buckets[key]?.sorted { $0.beginDate > $1.beginDate } ?? [])
        }
    }

    private func formatDay(_ key: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "de_DE")
        out.dateFormat = "EEEE, dd.MM.yyyy"
        return out.string(from: date)
    }
}
