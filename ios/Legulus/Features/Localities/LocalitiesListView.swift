import SwiftUI

struct LocalitiesListView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        NavigationStack {
            LocalitiesListScreen(
                store: container.localitiesStore,
                hydrator: container.localitiesHydrator
            )
        }
    }
}

/// Internal so HomeView can embed it in its own NavigationStack.
struct LocalitiesListScreen: View {
    @StateObject private var viewModel: LocalitiesListViewModel
    @State private var presentingNew = false

    init(store: LocalLocalityStore, hydrator: LocalitiesHydrator) {
        _viewModel = StateObject(wrappedValue: LocalitiesListViewModel(
            store: store, hydrator: hydrator
        ))
    }

    var body: some View {
        content
            .navigationTitle("Fundorte")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        LocalitiesMapView()
                    } label: {
                        Image(systemName: "map")
                            .accessibilityLabel("Karte")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentingNew = true
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Neuen Fundort anlegen")
                    }
                }
            }
            .onAppear { viewModel.start() }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $presentingNew) {
                LocalityEditView(editing: nil)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.localities.isEmpty {
            if viewModel.isHydrating {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        } else {
            List {
                if !viewModel.reviewPending.isEmpty {
                    Section {
                        ForEach(viewModel.reviewPending) { locality in
                            localityLink(locality)
                        }
                    } header: {
                        Text("Prüfen")
                    } footer: {
                        Text("Möglicherweise doppelte Fundorte — beim Auswerten zusammenführen oder behalten.")
                    }
                }
                Section {
                    ForEach(viewModel.regular) { locality in
                        localityLink(locality)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func localityLink(_ locality: LocalLocality) -> some View {
        NavigationLink {
            LocalityDetailView(localityID: locality.id)
        } label: {
            row(for: locality)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch keine Fundorte", systemImage: "mappin.slash")
        } description: {
            if let err = viewModel.hydratingError {
                Text("Backend nicht erreichbar: \(err)")
            } else {
                Text("Mit + einen Fundort anlegen — typisch beim Auswerten zuhause, nicht im Feld.")
            }
        } actions: {
            Button("Neu anlegen") { presentingNew = true }
        }
    }

    private func row(for locality: LocalLocality) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
                Text(locality.name.isEmpty ? "(ohne Namen)" : locality.name)
                    .font(.body.weight(.medium))
                if locality.needsHumanReview {
                    reviewBadge
                }
            }
            if let lat = locality.centroidLat, let lon = locality.centroidLon {
                Text(String(format: "%.5f, %.5f", lat, lon))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let radius = locality.radiusM {
                Text("Radius \(Int(radius)) m")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    /// "möglicherweise doppelt" — icon + text so it reads without
    /// relying on colour alone (differentiateWithoutColor).
    private var reviewBadge: some View {
        HStack(spacing: AppSpacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("möglicherweise doppelt")
        }
        .font(AppFont.caption)
        .foregroundStyle(AppColor.warning)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Möglicherweise doppelter Fundort")
    }
}
