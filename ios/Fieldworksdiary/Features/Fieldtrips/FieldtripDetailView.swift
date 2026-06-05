import SwiftUI

struct FieldtripDetailView: View {
    let fieldtripID: String

    @EnvironmentObject var container: AppContainer
    @State private var local: LocalFieldtrip?
    @State private var loadingError: String?
    @State private var localityActionError: String?
    @State private var localityActionBusy = false
    @State private var labelGenerating = false
    @State private var labelError: String?
    @State private var labelPDFURL: URL?
    @State private var labelTemplate: LabelTemplate = .defaultA6
    @State private var previousLabels: [LabelPDF] = []
    @State private var loadingPreviousLabels = false
    @State private var presentingPermitEdit = false
    @State private var permitPDFLocalURL: URL?

    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let current = local {
                    header(current)
                    localitySection(current)
                    permitSection(current)
                    samplesSection
                    if let astro = current.astro {
                        GroupBox {
                            AstroPanel(astro: astro, timeZone: berlin)
                        }
                    } else {
                        GroupBox("Astro") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { ProgressView().controlSize(.small)
                                    Text("Wird berechnet …")
                                }
                                .foregroundStyle(.secondary)
                                Text("Sonnen- und Mondzeiten erscheinen, sobald die Anreicherung durchgelaufen ist.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ProgressView().padding()
                }
                if let error = loadingError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(local.map(displayName) ?? "Exkursion")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func permitSection(_ current: LocalFieldtrip) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Genehmigung")
                        .font(.headline)
                    Spacer()
                    Button("Bearbeiten") { presentingPermitEdit = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let number = current.permitNumber, !number.isEmpty {
                    Label(number, systemImage: "checkmark.seal")
                        .font(.body.monospaced())
                } else {
                    Text("Keine Genehmigungs-Nummer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let pdf = current.permitPDFFile, !pdf.isEmpty {
                    Button {
                        Task { await openPermitPDF(filename: pdf) }
                    } label: {
                        Label(pdf, systemImage: "doc.text.fill")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $presentingPermitEdit) {
            PermitEditSheet(fieldtripID: fieldtripID, current: current) {
                Task {
                    local = (try? container.fieldtrips.fetchById(fieldtripID)) ?? local
                }
            }
        }
        .sheet(item: Binding(
            get: { permitPDFLocalURL.map(IdentifiableURL.init) },
            set: { permitPDFLocalURL = $0?.url }
        )) { item in
            PDFShareSheet(url: item.url)
        }
    }

    private func openPermitPDF(filename: String) async {
        let endpoint = container.config.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty,
              let url = URL(string: endpoint.appending(
                  "/api/files/fieldtrips/\(fieldtripID)/\(filename)"
              )) else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dest = caches.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            permitPDFLocalURL = dest
        } catch {
            // best-effort — log but don't surface to user
            Log.network.error("permit PDF download failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private var samplesSection: some View {
        let samples = (try? container.store.fetchByFieldtrip(fieldtripID)) ?? []
        let syncedSamples = samples.filter { $0.backendId != nil }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Proben")
                        .font(.headline)
                    Spacer()
                    Text("\(samples.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if samples.isEmpty {
                    Text("Noch keine lokalen Proben für diese Exkursion.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(samples) { s in
                        NavigationLink {
                            SampleEditorView(sampleID: s.id)
                        } label: {
                            sampleRow(s)
                        }
                        .buttonStyle(.plain)
                        if s != samples.last { Divider() }
                    }
                    Divider()
                    labelPDFRow(syncedSamples: syncedSamples)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: Binding(
            get: { labelPDFURL.map(IdentifiableURL.init) },
            set: { labelPDFURL = $0?.url }
        )) { item in
            PDFShareSheet(url: item.url)
        }
    }

    private func labelPDFRow(syncedSamples: [LocalSample]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Etiketten drucken")
                .font(.subheadline.weight(.semibold))

            Picker("Layout", selection: $labelTemplate) {
                ForEach(LabelTemplate.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button {
                    Task { await generateLabels(kind: .locality, samples: syncedSamples) }
                } label: {
                    Label("Locality", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    Task { await generateLabels(kind: .determination, samples: syncedSamples) }
                } label: {
                    Label("Determination", systemImage: "doc.text.below.ecg")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(labelGenerating || syncedSamples.isEmpty)

            if labelGenerating {
                HStack { ProgressView().controlSize(.small)
                    Text("Erzeuge PDF …")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if syncedSamples.isEmpty {
                Text("Nur gesyncte Proben können gedruckt werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let labelError {
                Text(labelError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !previousLabels.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Bisherige PDFs")
                    .font(.subheadline.weight(.semibold))
                ForEach(previousLabels) { label in
                    Button {
                        Task { await openExisting(label) }
                    } label: {
                        previousLabelRow(label)
                    }
                    .buttonStyle(.plain)
                    if label != previousLabels.last { Divider() }
                }
            }
        }
        .task(id: fieldtripID) { await reloadPreviousLabels(for: syncedSamples) }
    }

    private enum LabelKind { case locality, determination }

    private func generateLabels(kind: LabelKind, samples: [LocalSample]) async {
        let ids = samples.compactMap(\.backendId)
        guard !ids.isEmpty else { return }
        labelGenerating = true
        labelError = nil
        defer { labelGenerating = false }
        do {
            let client = LabelClient(endpoint: container.config.endpointURL, auth: container.auth)
            let label: LabelPDF
            switch kind {
            case .locality:
                label = try await client.generateLocality(sampleIDs: ids, template: labelTemplate)
            case .determination:
                label = try await client.generateDetermination(sampleIDs: ids, template: labelTemplate)
            }
            let url = try await client.downloadPDF(label)
            labelPDFURL = url
            await reloadPreviousLabels(for: samples)
        } catch let err as SampleClientError {
            labelError = err.errorDescription
        } catch {
            labelError = error.localizedDescription
        }
    }

    private func openExisting(_ label: LabelPDF) async {
        labelGenerating = true
        defer { labelGenerating = false }
        do {
            let client = LabelClient(endpoint: container.config.endpointURL, auth: container.auth)
            labelPDFURL = try await client.downloadPDF(label)
        } catch let err as SampleClientError {
            labelError = err.errorDescription
        } catch {
            labelError = error.localizedDescription
        }
    }

    private func reloadPreviousLabels(for samples: [LocalSample]) async {
        let ids = samples.compactMap(\.backendId)
        guard !ids.isEmpty else { previousLabels = []
            return
        }
        loadingPreviousLabels = true
        defer { loadingPreviousLabels = false }
        let client = LabelClient(endpoint: container.config.endpointURL, auth: container.auth)
        if let items = try? await client.listForSamples(ids) {
            previousLabels = items
        }
    }

    private func previousLabelRow(_ label: LabelPDF) -> some View {
        HStack(spacing: 10) {
            Image(systemName: label.kind == "determination"
                ? "doc.text.below.ecg"
                : "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(humanReadableKind(label.kind))
                    .font(.body)
                HStack(spacing: 6) {
                    if !label.template.isEmpty {
                        Text(label.template).font(.caption.monospaced())
                    }
                    if let date = label.created {
                        Text(formatPDFDate(date)).font(.caption.monospacedDigit())
                    }
                    Text("· \(label.samples.count) Etikett\(label.samples.count == 1 ? "" : "en")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func humanReadableKind(_ raw: String) -> String {
        switch raw {
        case "locality": "Locality-Etiketten"
        case "determination": "Determinations-Etiketten"
        default: raw
        }
    }

    private func formatPDFDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = berlin
        formatter.dateFormat = "dd.MM. HH:mm"
        return formatter.string(from: date)
    }

    private func sampleRow(_ sample: LocalSample) -> some View {
        HStack {
            Text(sample.sampleID)
                .font(.system(.body, design: .monospaced).weight(.medium))
            Spacer()
            if sample.adminUnitsLocality == nil && sample.syncStatus != .synced {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .accessibilityLabel("Anreicherung läuft")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func displayName(_ fieldtrip: LocalFieldtrip) -> String {
        if !fieldtrip.title.isEmpty { return fieldtrip.title }
        return "Sammeltag \(fieldtrip.collectingDay)"
    }

    private func header(_ current: LocalFieldtrip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(current.collectingDay)
                    .font(.title3.monospacedDigit())
                if current.nightFieldtrip {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(.indigo)
                        .accessibilityLabel("Nacht-Exkursion")
                }
            }
            if let started = current.beginDate, let ended = current.endDate {
                Text("\(formatDateTime(started)) – \(formatDateTime(ended))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let admin = current.adminUnits, let locality = admin.locality {
                Text(locality)
                    .font(.body.weight(.medium))
                if let area = admin.adminArea, let country = admin.country {
                    Text("\(country), \(area)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let mtb = current.mtb, let sheetNumber = mtb.sheetNumber, let sheetName = mtb.sheetName {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("MTB \(sheetNumber) — \(sheetName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let lat = current.centroidLat, let lon = current.centroidLon {
                Text(String(format: "Centroid %.5f, %.5f", lat, lon))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func localitySection(_ current: LocalFieldtrip) -> some View {
        if let assignedID = current.locality,
           let assigned = try? container.localitiesStore.fetchById(assignedID)
        {
            GroupBox("Fundort") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text(assigned.name).font(.body.weight(.medium))
                    }
                    Button(role: .destructive) {
                        Task { await unassignLocality() }
                    } label: {
                        Label("Zuordnung entfernen", systemImage: "minus.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(localityActionBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let suggestedID = current.suggestedLocality,
                  let suggested = try? container.localitiesStore.fetchById(suggestedID)
        {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Vorschlag", systemImage: "lightbulb")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Diese Exkursion liegt vermutlich im Fundort **\(suggested.name)**.")
                    HStack {
                        Button {
                            Task { await acceptSuggestion(suggested.id) }
                        } label: {
                            Label("Zuordnen", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .cancel) {
                            // No backend "reject" — the suggestion
                            // simply stays until the user assigns
                            // something or the centroid moves.
                        } label: {
                            Text("Später")
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(localityActionBusy)
                    if let msg = localityActionError {
                        Text(msg).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = berlin
        formatter.dateFormat = "dd.MM. HH:mm"
        return formatter.string(from: date)
    }

    private func reload() async {
        local = (try? container.fieldtrips.fetchById(fieldtripID))
        await container.hydrator.pullOne(fieldtripID)
        local = (try? container.fieldtrips.fetchById(fieldtripID)) ?? local
        loadingError = container.hydrator.lastError
    }

    private func acceptSuggestion(_ localityID: String) async {
        localityActionBusy = true
        defer { localityActionBusy = false }
        do {
            let client = FieldtripClient(endpoint: container.config.endpointURL, auth: container.auth)
            let updated = try await client.setLocality(id: fieldtripID, locality: localityID)
            try container.fieldtrips.upsert([updated])
            local = try? container.fieldtrips.fetchById(fieldtripID)
            localityActionError = nil
        } catch let err as SampleClientError {
            localityActionError = err.errorDescription
        } catch {
            localityActionError = error.localizedDescription
        }
    }

    private func unassignLocality() async {
        localityActionBusy = true
        defer { localityActionBusy = false }
        do {
            let client = FieldtripClient(endpoint: container.config.endpointURL, auth: container.auth)
            let updated = try await client.setLocality(id: fieldtripID, locality: nil)
            try container.fieldtrips.upsert([updated])
            local = try? container.fieldtrips.fetchById(fieldtripID)
            localityActionError = nil
        } catch let err as SampleClientError {
            localityActionError = err.errorDescription
        } catch {
            localityActionError = error.localizedDescription
        }
    }
}
