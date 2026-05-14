import SwiftUI
import CoreLocation

/// Outer view: pulls dependencies out of the environment and hands
/// them to the inner screen, which owns the view model. This is the
/// canonical SwiftUI pattern for @StateObject + injected deps.
struct AddSampleView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        AddSampleScreen(store: container.store, sync: container.sync)
    }
}

private struct AddSampleScreen: View {
    @StateObject private var location = LocationProvider()
    @StateObject private var viewModel: AddSampleViewModel

    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var showingPicker = false

    init(store: LocalSampleStore, sync: SyncRunner) {
        _viewModel = StateObject(wrappedValue: AddSampleViewModel(store: store, sync: sync))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    gpsCard
                    if pickedCoordinate != nil {
                        manualCoordinateCard
                    }
                    resultCard
                    submitButton
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Koordinate manuell setzen", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Neue Probe")
            .onAppear { location.requestFix() }
            .onChange(of: location.status) { _, newValue in
                viewModel.update(from: newValue)
            }
            .sheet(isPresented: $showingPicker) {
                CoordinatePickerView(selected: $pickedCoordinate, initialFix: viewModel.lastFix)
            }
        }
    }

    @ViewBuilder
    private var manualCoordinateCard: some View {
        GroupBox("Manuelle Koordinate") {
            VStack(alignment: .leading, spacing: 6) {
                if let c = pickedCoordinate {
                    Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                        .font(.body.monospacedDigit())
                    Text("Wird statt GPS verwendet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Bearbeiten") { showingPicker = true }
                    Button("Verwerfen", role: .destructive) { pickedCoordinate = nil }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var gpsCard: some View {
        GroupBox("GPS") {
            switch location.status {
            case .idle:
                Text("Initialisiere …").foregroundStyle(.secondary)
            case .requestingAuthorization:
                Text("Frage Zugriffsrecht an …").foregroundStyle(.secondary)
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Standortzugriff verweigert.").foregroundStyle(.red)
                    Text("In den iOS-Einstellungen freigeben, dann erneut probieren.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .locating:
                HStack { ProgressView(); Text("Suche Position …") }
                    .foregroundStyle(.secondary)
            case .fixed(let loc):
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.6f, %.6f", loc.coordinate.latitude, loc.coordinate.longitude))
                        .font(.body.monospacedDigit())
                    if loc.horizontalAccuracy >= 0 {
                        Text(String(format: "± %.0f m", loc.horizontalAccuracy))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Erneut messen") { location.requestFix() }
                        .font(.footnote).padding(.top, 4)
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Text("GPS-Fehler.").foregroundStyle(.red)
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                    Button("Erneut versuchen") { location.requestFix() }.font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var resultCard: some View {
        switch viewModel.phase {
        case .idle:
            EmptyView()
        case .savingLocal:
            HStack { ProgressView(); Text("Speichere lokal …") }
                .foregroundStyle(.secondary)
        case .localSaved(let sample):
            successCard(sample)
        case .error(let msg):
            GroupBox("Fehler") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg).foregroundStyle(.red)
                    Button("Verwerfen") { viewModel.reset() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func successCard(_ s: LocalSample) -> some View {
        GroupBox("Gespeichert") {
            VStack(alignment: .leading, spacing: 12) {
                Text(s.code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                if let backendCode = s.backendCode, backendCode != s.code {
                    Text("Server-Code: \(backendCode) — Original \(s.code) bleibt auf dem Röhrchen.")
                        .font(.footnote).foregroundStyle(.orange)
                }

                syncStatusBadge(s)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    if let locality = s.adminUnitsLocality {
                        Label {
                            VStack(alignment: .leading) {
                                Text(locality).font(.body.weight(.medium))
                                if let country = s.adminUnitsCountry {
                                    Text(country).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                    } else if s.syncStatus != .synced {
                        Text("Anreicherung nach Sync.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    if let sheet = s.mtbSheetName {
                        Label("MTB \(sheet)", systemImage: "square.grid.2x2")
                    }
                }

                Button("Nächste Probe") { viewModel.reset() }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func syncStatusBadge(_ s: LocalSample) -> some View {
        switch s.syncStatus {
        case .pending:
            Label("wartet auf Sync", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("synchronisiere …")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .synced:
            Label("gesynct", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("Sync fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let err = s.syncError, !err.isEmpty {
                    Text(err).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Erneut versuchen") { viewModel.retrySync() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .font(.caption)
        }
    }

    private var submitButton: some View {
        Button {
            Task { await viewModel.submit(overrideCoordinate: pickedCoordinate) }
        } label: {
            Text("Probe anlegen")
                .frame(maxWidth: .infinity, minHeight: 48)
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .disabled(submitDisabled)
    }

    private var submitDisabled: Bool {
        if viewModel.phase == .savingLocal { return true }
        if pickedCoordinate != nil { return false }
        if case .fixed = location.status { return false }
        return true
    }
}
