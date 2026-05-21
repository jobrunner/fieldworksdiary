import SwiftUI
import UniformTypeIdentifiers

/// Sheet to edit the per-excursion research permit. Two independent
/// fields: the number (text, ends up on labels) and an optional PDF
/// archive. The user can change either or both in one go.
struct PermitEditSheet: View {
    let excursionID: String
    let current: LocalExcursion
    let onSaved: () -> Void

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var numberDraft: String = ""
    @State private var pickedFile: URL? = nil
    @State private var presentingPicker = false
    @State private var saving = false
    @State private var error: String?
    @State private var clearPDF = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. BV-2026/123", text: $numberDraft)
                        .autocorrectionDisabled()
                } header: {
                    Text("Genehmigungs-Nummer")
                } footer: {
                    Text("Wird auf Locality-Etiketten ausgegeben, wenn gesetzt.")
                }
                Section {
                    if let url = pickedFile {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                pickedFile = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    } else if let existing = current.permitPDFFile, !existing.isEmpty, !clearPDF {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.tint)
                            Text(existing).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                clearPDF = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    } else if clearPDF {
                        Label("PDF wird beim Speichern entfernt.",
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Kein PDF hochgeladen.")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        presentingPicker = true
                    } label: {
                        Label("PDF auswählen", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Genehmigungs-PDF")
                } footer: {
                    Text("Optional, nur fürs Archiv. Bleibt auf dem Backend liegen.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Genehmigung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") { Task { await save() } }
                        .disabled(saving || !hasChanges)
                        .fontWeight(.semibold)
                }
            }
            .fileImporter(isPresented: $presentingPicker,
                          allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    // Move into our caches so we don't have to keep
                    // the document-picker security scope open later.
                    pickedFile = copyIntoCaches(url)
                    clearPDF = false
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
            .onAppear {
                numberDraft = current.permitNumber ?? ""
            }
        }
    }

    private var hasChanges: Bool {
        if numberDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (current.permitNumber ?? "") {
            return true
        }
        if pickedFile != nil { return true }
        if clearPDF { return true }
        return false
    }

    private func copyIntoCaches(_ src: URL) -> URL? {
        let didSecure = src.startAccessingSecurityScopedResource()
        defer { if didSecure { src.stopAccessingSecurityScopedResource() } }
        do {
            let caches = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dest = caches.appendingPathComponent("permit-\(UUID().uuidString).pdf")
            try FileManager.default.copyItem(at: src, to: dest)
            return dest
        } catch {
            self.error = "Datei konnte nicht gelesen werden: \(error.localizedDescription)"
            return nil
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let client = ExcursionClient(endpoint: container.config.endpointURL, auth: container.auth)
        let trimmedNumber = numberDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // The three meaningful cases:
            //   1. upload a new PDF (with or without number change)
            //   2. clear the existing PDF
            //   3. only the number changed
            var updated: Excursion
            if let file = pickedFile {
                updated = try await client.uploadPermitPDF(
                    id: excursionID, fileURL: file, permitNumber: trimmedNumber
                )
            } else if clearPDF {
                updated = try await client.clearPermitPDF(id: excursionID, clearNumber: false)
                if trimmedNumber != (current.permitNumber ?? "") {
                    updated = try await client.setPermitNumber(id: excursionID, number: trimmedNumber)
                }
            } else {
                updated = try await client.setPermitNumber(id: excursionID, number: trimmedNumber)
            }
            try container.excursions.upsert([updated])
            onSaved()
            dismiss()
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
