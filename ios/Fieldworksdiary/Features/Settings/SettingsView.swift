import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var auth: AuthSession
    @State private var draft: String = ""
    @State private var savedHint: Bool = false
    @State private var confirmSignOut: Bool = false
    @State private var showDeleteSheet: Bool = false
    @State private var exportState: ExportState = .idle

    private enum ExportState: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                dataSection
                endpointSection
            }
            .navigationTitle("Einstellungen")
            .onAppear { draft = config.endpointURL }
            .onChange(of: draft) { _, _ in savedHint = false }
            .confirmationDialog("Wirklich abmelden?",
                                isPresented: $confirmSignOut,
                                titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { auth.signOut() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Lokale Daten bleiben erhalten. Der Token wird aus dem Schlüsselbund entfernt.")
            }
            .sheet(isPresented: $showDeleteSheet) {
                AccountDeletionView()
                    .environmentObject(auth)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let user = auth.currentUser {
            Section {
                LabeledContent("E-Mail", value: user.email)
                if !user.displayName.isEmpty {
                    LabeledContent("Name", value: user.displayName)
                }
                if !user.abbreviation.isEmpty {
                    LabeledContent("Kürzel", value: user.abbreviation)
                }
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) {
                    showDeleteSheet = true
                } label: {
                    Label("Account löschen", systemImage: "trash")
                }
            } header: {
                Text("Konto")
            } footer: {
                Text("Beim Löschen werden Account und alle damit verknüpften Daten unwiderruflich entfernt.")
            }
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        Section {
            switch exportState {
            case .idle:
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Daten exportieren", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(config.endpointURL.isEmpty || !auth.isSignedIn)
            case .downloading:
                HStack {
                    ProgressView()
                    Text("Export wird erstellt …")
                }
            case .ready(let url):
                ShareLink(item: url) {
                    Label("Export teilen", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Neu erstellen", systemImage: "arrow.clockwise")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Daten")
        } footer: {
            Text("Lädt alle eigenen Datensätze und PDFs als ZIP-Archiv vom Backend.")
        }
    }

    private var endpointSection: some View {
        Section {
            TextField("http://192.168.1.10:8090", text: $draft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Speichern") {
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                config.endpointURL = trimmed
                draft = trimmed
                savedHint = true
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == config.endpointURL)
        } header: {
            Text("Backend-Endpoint")
        } footer: {
            if savedHint {
                Text("Gespeichert.")
            } else {
                Text("Beispiel: http://localhost:8090 (Simulator) oder http://<host-ip>:8090 (Gerät).")
            }
        }
    }

    private func runExport() async {
        exportState = .downloading
        let client = ExportClient(endpoint: config.endpointURL, auth: auth)
        do {
            let url = try await client.downloadExport()
            exportState = .ready(url)
        } catch let err as SampleClientError {
            exportState = .failed(err.errorDescription ?? "Export fehlgeschlagen.")
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }
}
