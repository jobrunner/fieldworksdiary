import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            SettingsScreen()
        }
    }
}

/// Internal so HomeView can embed it in its own NavigationStack.
struct SettingsScreen: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var auth: AuthSession
    @State private var draft: String = ""
    @State private var savedHint: Bool = false
    @State private var ortusDraft: String = ""
    @State private var ortusSavedHint: Bool = false
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
        Form {
            accountSection
            dataSection
            sampleCodeSection
            endpointSection
            ortusEndpointSection
            aboutSection
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EnvBadge(environment: config.environment)
            }
        }
        .onAppear {
            draft = config.endpointURL
            ortusDraft = config.ortusEndpointURL
        }
        .onChange(of: draft) { _, _ in savedHint = false }
        .onChange(of: ortusDraft) { _, _ in ortusSavedHint = false }
        .confirmationDialog("Wirklich abmelden?",
                            isPresented: $confirmSignOut,
                            titleVisibility: .visible)
        {
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
            case let .ready(url):
                ShareLink(item: url) {
                    Label("Export teilen", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Neu erstellen", systemImage: "arrow.clockwise")
                }
            case let .failed(message):
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

    private var sampleCodeSection: some View {
        Section {
            Picker("Format", selection: $config.sampleCodeTemplate) {
                ForEach(SampleCodeTemplate.presets, id: \.raw) { preset in
                    Text(preset.raw).monospaced().tag(preset.raw)
                }
            }
            LabeledContent("Beispiel") {
                Text(sampleCodePreview)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Sample-ID-Format")
        } footer: {
            Text(
                "Provisorisches Format für neue Proben. Tokens: <YY>/<YYYY>, <MM>, <DD>, <seq>. Das Backend kann die ID beim Sync neu vergeben."
            )
        }
    }

    /// Renders today's first sample id under the selected template, so
    /// the user sees the effect before creating a sample.
    private var sampleCodePreview: String {
        SampleCodeTemplate(raw: config.sampleCodeTemplate)
            .format(day: Date(), sequence: 1, timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current)
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

    /// Ortus is queried directly from the device after a sample is
    /// saved; an empty value switches that off.
    private var ortusEndpointSection: some View {
        Section {
            TextField("Ortus-Endpoint", text: $ortusDraft,
                      prompt: Text(AppConfig.defaultOrtusEndpointURL))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Speichern") {
                let trimmed = ortusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                config.ortusEndpointURL = trimmed
                ortusDraft = trimmed
                ortusSavedHint = true
            }
            .disabled(ortusDraft.trimmingCharacters(in: .whitespacesAndNewlines) == config.ortusEndpointURL)
        } header: {
            Text("Ortus-Endpoint")
        } footer: {
            if ortusSavedHint {
                Text("Gespeichert.")
            } else {
                Text("Geodienst für Ort, Höhe und MTB direkt beim Anlegen einer Probe. Leer lassen, um die Abfrage auf dem Gerät abzuschalten – das Backend ergänzt die Daten dann nach dem Sync.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Link(destination: config.privacyPolicyURL) {
                Label("Datenschutzerklärung", systemImage: "hand.raised")
            }
            #if DEBUG
                NavigationLink {
                    DesignCatalogView()
                } label: {
                    Label("Design-Katalog", systemImage: "paintpalette")
                }
            #endif
        } header: {
            Text("Rechtliches")
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
