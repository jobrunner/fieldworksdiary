import SwiftUI

struct ExcursionsListView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        NavigationStack {
            ExcursionsListScreen(
                store: container.excursions,
                hydrator: container.hydrator
            )
        }
    }
}

/// Internal so HomeView can embed it inside the dashboard's own
/// NavigationStack without nesting a second one.
struct ExcursionsListScreen: View {
    @StateObject private var viewModel: ExcursionsListViewModel
    @State private var presentingFilter = false

    init(store: LocalExcursionStore, hydrator: ExcursionsHydrator) {
        _viewModel = StateObject(wrappedValue: ExcursionsListViewModel(
            store: store, hydrator: hydrator
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
                ExcursionsFilterSheet(
                    filter: $viewModel.filter,
                    countries: viewModel.knownCountries
                )
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
        HStack(spacing: 6) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        List(viewModel.visible) { excursion in
            NavigationLink {
                ExcursionDetailView(excursionID: excursion.id)
            } label: {
                row(for: excursion)
            }
        }
        .listStyle(.plain)
    }

    private func row(for excursion: LocalExcursion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayName(excursion))
                    .font(.body.weight(.medium))
                Spacer()
                if excursion.nightExcursion {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(.indigo)
                        .accessibilityLabel("Nachtexkursion")
                }
            }
            HStack(spacing: 8) {
                Text(excursion.collectingDay)
                    .font(.footnote.monospacedDigit())
                if let locality = excursion.adminUnits?.locality, !locality.isEmpty {
                    Text("·")
                    Text(locality)
                }
                if let mtb = excursion.mtb?.sheetNumber, !mtb.isEmpty {
                    Text("· MTB \(mtb)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func displayName(_ excursion: LocalExcursion) -> String {
        if !excursion.name.isEmpty { return excursion.name }
        return "Sammeltag \(excursion.collectingDay)"
    }
}
