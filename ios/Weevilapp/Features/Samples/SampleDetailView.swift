import SwiftUI

struct SampleDetailView: View {
    let sample: LocalSample

    @EnvironmentObject var container: AppContainer
    @State private var determinations: [Determination] = []
    @State private var loadingDeterminations = false
    @State private var loadError: String?
    @State private var presentingNew = false
    @State private var editing: Determination?
    @State private var people: [String: Person] = [:]  // id → person (for label lookup)

    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                codeCard
                metadataCard
                determinationsSection
            }
            .padding()
        }
        .navigationTitle(sample.code)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshDeterminations()
        }
        .refreshable { await refreshDeterminations() }
        .sheet(isPresented: $presentingNew) {
            DeterminationEditView(
                mode: .create(sampleID: sample.backendId ?? sample.id),
                onSaved: { _ in Task { await refreshDeterminations() } },
                onDeleted: nil
            )
        }
        .sheet(item: $editing) { det in
            DeterminationEditView(
                mode: .edit(existing: det),
                onSaved: { _ in Task { await refreshDeterminations() } },
                onDeleted: { Task { await refreshDeterminations() } }
            )
        }
    }

    @ViewBuilder
    private var codeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(sample.code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                if let backendCode = sample.backendCode, backendCode != sample.code {
                    Text("Server: \(backendCode) — Original \(sample.code)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metadataCard: some View {
        GroupBox("Probe") {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(format: "%.6f, %.6f", sample.lat, sample.lon),
                      systemImage: "mappin.and.ellipse")
                    .font(.body.monospacedDigit())
                if let acc = sample.accuracyM {
                    Text(String(format: "± %.0f m", acc))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Label(formatDateTime(sample.collectedFrom), systemImage: "calendar")
                    .font(.footnote)
                if let locality = sample.adminUnitsLocality {
                    Label(locality, systemImage: "globe.europe.africa")
                        .font(.footnote)
                }
                if let mtb = sample.mtbSheetNumber, !mtb.isEmpty {
                    Label("MTB \(mtb)", systemImage: "square.grid.2x2")
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var determinationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Bestimmungen")
                        .font(.headline)
                    Spacer()
                    Button {
                        presentingNew = true
                    } label: {
                        Label("Neu", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sample.backendId == nil)
                }

                if sample.backendId == nil {
                    Text("Bestimmung erst nach erfolgtem Sync möglich.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if loadingDeterminations && determinations.isEmpty {
                    ProgressView()
                } else if determinations.isEmpty {
                    Text("Noch keine Bestimmung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(determinations) { det in
                        Button { editing = det } label: { determinationRow(det) }
                            .buttonStyle(.plain)
                        if det != determinations.last { Divider() }
                    }
                }

                if let err = loadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func determinationRow(_ det: Determination) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(det.kind.labelShort)
                .font(.system(.body, design: .monospaced))
                .frame(width: 40, alignment: .leading)
                .foregroundStyle(det.kind == .det ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(det.speciesText)
                    .font(.body.italic())
                HStack(spacing: 6) {
                    if let id = det.person, let p = people[id], !p.abbreviation.isEmpty {
                        Text(p.abbreviation)
                    }
                    if let on = det.determinedOn {
                        Text(shortDate(on))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if !det.notes.isEmpty {
                    Text(det.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = berlin
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f.string(from: date)
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = berlin
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }

    private func refreshDeterminations() async {
        guard let backendID = sample.backendId else { return }
        loadingDeterminations = true
        defer { loadingDeterminations = false }
        do {
            let detClient = DeterminationClient(endpoint: container.config.endpointURL, auth: container.auth)
            let list = try await detClient.listBySample(backendID)
            determinations = list
            loadError = nil
            await refreshPeopleCache(forIDs: Set(list.compactMap(\.person)))
        } catch let err as SampleClientError {
            loadError = err.errorDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshPeopleCache(forIDs ids: Set<String>) async {
        let missing = ids.subtracting(people.keys)
        guard !missing.isEmpty else { return }
        if let all = try? await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).listAll() {
            for p in all where ids.contains(p.id) {
                people[p.id] = p
            }
        }
    }
}
