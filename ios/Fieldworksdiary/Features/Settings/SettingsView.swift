import FieldworksGeo
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
            sampleIDSection
            rolloverSection
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
        .onChange(of: config.sampleIDFormat) { _, _ in pushUserSettings() }
        .onChange(of: config.sampleIDPrefix) { _, _ in pushUserSettings() }
        .onChange(of: config.sampleIDOffset) { _, _ in pushUserSettings() }
        .onChange(of: config.dayCutoffHour) { _, _ in pushUserSettings() }
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

    private var sampleIDSection: some View {
        Section {
            Picker("Format", selection: $config.sampleIDFormat) {
                ForEach(SampleIDTemplate.presets, id: \.raw) { preset in
                    Text(Self.presetLabel(preset)).monospaced().tag(preset.raw)
                }
            }
            TextField("Präfix", text: $config.sampleIDPrefix)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if currentTemplate.counter == .running {
                Stepper(value: $config.sampleIDOffset, in: 0 ... Int.max) {
                    LabeledContent("Offset", value: "\(config.sampleIDOffset)")
                }
            }
            LabeledContent("Nächster Vorschlag") {
                Text(sampleIDPreview)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Sample-ID")
        } footer: {
            Text(
                "Tokens: <YY>/<YYYY>, <MM>, <DD>, <PREFIX>, <seq> (Tageszähler) oder <n> (laufender Zähler). Das Backend kann die ID beim Sync um ein Suffix ergänzen, falls sie schon vergeben ist."
            )
        }
    }

    private var rolloverSection: some View {
        Section {
            Picker("Tagesrollover", selection: $config.dayCutoffHour) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    Text("\(hour):00").tag(hour)
                }
            }
        } footer: {
            Text("Gilt in der Ortszeit des Samples.")
        }
    }

    private var currentTemplate: SampleIDTemplate {
        SampleIDTemplate(raw: config.sampleIDFormat)
    }

    private static func presetLabel(_ preset: SampleIDTemplate) -> String {
        preset == .empty ? "– (leer lassen)" : preset.raw
    }

    /// Next suggestion for today's collecting day, so the user sees the
    /// effect of format, prefix and offset before creating a sample.
    private var sampleIDPreview: String {
        let day = SampleTime.collectingDay(Date(), cutoffHour: config.dayCutoffHour, in: .current)
        let suggestion = SampleIDTemplate.nextSuggestion(
            template: currentTemplate,
            prefix: config.sampleIDPrefix,
            day: day,
            existingIDs: [],
            lastRunning: config.lastRunningNumber,
            offset: config.sampleIDOffset
        )
        return suggestion.id.isEmpty ? "–" : suggestion.id
    }

    /// Best-effort sync to the users record. Skipped when the record
    /// already holds these values (e.g. after taking them from it).
    private func pushUserSettings() {
        let format = config.sampleIDFormat
        let prefix = config.sampleIDPrefix
        let offset = config.sampleIDOffset
        let cutoff = config.dayCutoffHour
        if let user = auth.currentUser,
           (user.sampleIDFormat ?? SampleIDTemplate.default.raw) == format,
           (user.sampleIDPrefix ?? "") == prefix,
           (user.sampleIDOffset ?? 0) == offset,
           user.dayCutoffHour == cutoff
        { return }
        Task {
            await auth.pushUserSettings(format: format, prefix: prefix, offset: offset, dayCutoffHour: cutoff)
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
