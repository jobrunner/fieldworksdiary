import SwiftUI

struct FieldtripsListView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        NavigationStack {
            FieldtripsListScreen(
                store: container.fieldtrips,
                hydrator: container.hydrator
            )
        }
    }
}

/// Internal so HomeView can embed it inside the dashboard's own
/// NavigationStack without nesting a second one.
struct FieldtripsListScreen: View {
    @StateObject private var viewModel: FieldtripsListViewModel
    @State private var presentingFilter = false

    init(store: LocalFieldtripStore, hydrator: FieldtripsHydrator) {
        _viewModel = StateObject(wrappedValue: FieldtripsListViewModel(
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
                FieldtripsFilterSheet(
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
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: 8) {
                Text(fieldtrip.collectingDay)
                    .font(.footnote.monospacedDigit())
                if let locality = fieldtrip.adminUnits?.locality, !locality.isEmpty {
                    Text("·")
                    Text(locality)
                }
                if let mtb = fieldtrip.mtb?.sheetNumber, !mtb.isEmpty {
                    Text("· MTB \(mtb)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func displayName(_ fieldtrip: LocalFieldtrip) -> String {
        if !fieldtrip.title.isEmpty { return fieldtrip.title }
        return "Sammeltag \(fieldtrip.collectingDay)"
    }
}
