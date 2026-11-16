import SwiftUI

/// Determinations block embedded at the bottom of the sample editor
/// for already-synced samples. Lifted from `SampleDetailView` so the
/// editor can serve as the single detail+edit surface.
///
/// Add/edit requires a backend id — until the create push has
/// landed, the add button is disabled with an explanatory hint.
struct SampleDeterminationsSection: View {
    let localSampleID: String
    let backendSampleID: String?

    @EnvironmentObject private var container: AppContainer

    @State private var determinations: [Determination] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var presentingNew = false
    @State private var editing: Determination?
    @State private var people: [String: Person] = [:]

    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current

    var body: some View {
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
                    .disabled(backendSampleID == nil)
                }

                if backendSampleID == nil {
                    Text("Bestimmung erst nach erfolgtem Sync möglich.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if loading, determinations.isEmpty {
                    ProgressView()
                } else if determinations.isEmpty {
                    Text("Noch keine Bestimmung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(determinations) { det in
                        Button { editing = det } label: { row(det) }
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
        // `.task(id:)` re-fires when the backend id transitions from
        // nil to non-nil (just-synced sample), so the determinations
        // list loads automatically once the row gains a backend id.
        .task(id: backendSampleID) { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $presentingNew) {
            if let backendSampleID {
                DeterminationEditView(
                    mode: .create(sampleID: backendSampleID),
                    onSaved: { _ in Task { await refresh() } },
                    onDeleted: nil
                )
            }
        }
        .sheet(item: $editing) { det in
            DeterminationEditView(
                mode: .edit(existing: det),
                onSaved: { _ in Task { await refresh() } },
                onDeleted: { Task { await refresh() } }
            )
        }
    }

    private func row(_ det: Determination) -> some View {
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
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = berlin
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }

    private func refresh() async {
        guard let backendSampleID else { return }
        loading = true
        defer { loading = false }
        do {
            let detClient = DeterminationClient(endpoint: container.config.endpointURL, auth: container.auth)
            let list = try await detClient.listBySample(backendSampleID)
            determinations = list
            loadError = nil
            await refreshPeople(forIDs: Set(list.compactMap(\.person)))
        } catch let err as SampleClientError {
            loadError = err.errorDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshPeople(forIDs ids: Set<String>) async {
        let missing = ids.subtracting(people.keys)
        guard !missing.isEmpty else { return }
        if let all = try? await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).listAll() {
            for p in all where ids.contains(p.id) {
                people[p.id] = p
            }
        }
    }
}
