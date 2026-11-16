import SwiftUI

struct FieldtripsListView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        NavigationStack {
            FieldtripsListScreen(
                store: container.fieldtrips,
                hydrator: container.hydrator,
                samples: container.store,
                placemarks: container.placemarksStore
            )
        }
    }
}

/// Internal so HomeView can embed it inside the dashboard's own
/// NavigationStack without nesting a second one.
struct FieldtripsListScreen: View {
    @StateObject private var viewModel: FieldtripsListViewModel
    @State private var presentingFilter = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        store: LocalFieldtripStore,
        hydrator: FieldtripsHydrator,
        samples: LocalSampleStore,
        placemarks: LocalPlacemarkStore
    ) {
        _viewModel = StateObject(wrappedValue: FieldtripsListViewModel(
            store: store, hydrator: hydrator, samples: samples, placemarks: placemarks
        ))
    }

    var body: some View {
        content
            .navigationTitle("Exkursionen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentingFilter = true
                    } label: {
                        Image(systemName: viewModel.filter.isActive
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                            .accessibilityLabel("Filter")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isHydrating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .accessibilityLabel("Aktualisieren")
                        }
                    }
                    .disabled(viewModel.isHydrating)
                }
            }
            .onAppear { viewModel.start() }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $presentingFilter) {
                FieldtripsFilterSheet(
                    filter: $viewModel.filter,
                    countries: viewModel.knownCountries
                )
                .onAppear { viewModel.reloadPlaces() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.all.isEmpty {
            if viewModel.isHydrating {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        } else if viewModel.visible.isEmpty {
            filterEmptyState
        } else {
            VStack(spacing: 0) {
                if viewModel.filter.isActive {
                    filterChip
                }
                list
            }
        }
    }

    private var filterChip: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .accessibilityHidden(true)
            Text("\(viewModel.visible.count) von \(viewModel.all.count) gefiltert")
                .font(.footnote)
            Spacer()
            Button("Aufheben") {
                viewModel.filter = .none
            }
            .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch keine Exkursionen", systemImage: "leaf")
        } description: {
            if let err = viewModel.hydratingError {
                Text("Backend nicht erreichbar: \(err)")
            } else {
                Text("Lege im Tab 'Neu' deine erste Probe an.")
            }
        } actions: {
            Button("Erneut laden") {
                Task { await viewModel.refresh() }
            }
        }
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("Keine Treffer", systemImage: "magnifyingglass")
        } description: {
            Text("Der aktive Filter passt auf keine Exkursion.")
        } actions: {
            Button("Filter aufheben") {
                viewModel.filter = .none
            }
        }
    }

    private var list: some View {
        List(viewModel.visible) { fieldtrip in
            NavigationLink {
                FieldtripDetailView(fieldtripID: fieldtrip.id)
            } label: {
                row(for: fieldtrip)
            }
        }
        .listStyle(.plain)
    }

    private func row(for fieldtrip: LocalFieldtrip) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Text(displayName(fieldtrip))
                    .font(.body.weight(.medium))
                Spacer()
                if fieldtrip.nightFieldtrip {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(.indigo)
                        .accessibilityLabel("Nachtexkursion")
                }
            }
            detailLine(for: fieldtrip)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, AppSpacing.xs)
        // One VoiceOver stop per fieldtrip; the hidden "·" separators
        // are not read.
        .accessibilityElement(children: .combine)
    }

    /// Date · place · MTB on one line while it fits; stacked otherwise
    /// (large Dynamic Type sizes), so nothing is truncated.
    @ViewBuilder
    private func detailLine(for fieldtrip: LocalFieldtrip) -> some View {
        let parts = detailParts(for: fieldtrip)
        if dynamicTypeSize.isAccessibilitySize {
            stackedDetail(parts)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            Text(verbatim: "·").accessibilityHidden(true)
                        }
                        detailText(part, isDate: index == 0)
                    }
                }
                stackedDetail(parts)
            }
        }
    }

    private func stackedDetail(_ parts: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                detailText(part, isDate: index == 0)
            }
        }
    }

    private func detailText(_ text: String, isDate: Bool) -> some View {
        Text(text)
            .font(isDate ? .footnote.monospacedDigit() : .footnote)
    }

    private func detailParts(for fieldtrip: LocalFieldtrip) -> [String] {
        Self.detailParts(collectingDay: fieldtrip.collectingDay, summary: viewModel.placeSummaries[fieldtrip.id])
    }

    /// Texts of the detail line, date first. Separators are not part of
    /// the texts: the one-line layout adds them as hidden views, the
    /// stacked layout needs none.
    static func detailParts(collectingDay: String, summary: FieldtripPlaceSummary?) -> [String] {
        var parts = [collectingDay]
        if let name = summary?.name { parts.append(name) }
        if let mtb = summary?.mtb { parts.append(mtb) }
        return parts
    }

    private func displayName(_ fieldtrip: LocalFieldtrip) -> String {
        if !fieldtrip.title.isEmpty { return fieldtrip.title }
        return "Sammeltag \(fieldtrip.collectingDay)"
    }
}
