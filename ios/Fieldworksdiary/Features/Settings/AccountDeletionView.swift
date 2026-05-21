import SwiftUI

/// Two-stage account deletion sheet. App Store guideline 5.1.1(v)
/// requires that any app offering account creation also offers
/// in-app account deletion with a clear, non-misleading flow — this
/// sheet is that flow.
///
/// The user must type the literal word `DELETE` to enable the
/// destructive button. We don't add a "trash icon → swipe" gesture
/// or similar shortcut; deletion is permanent and the friction is
/// the feature.
struct AccountDeletionView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var confirmation: String = ""
    @State private var busy: Bool = false
    @State private var error: String?

    private let requiredPhrase = "DELETE"

    private var canDelete: Bool {
        confirmation.trimmingCharacters(in: .whitespaces) == requiredPhrase && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Diese Aktion löscht deinen Account und alle damit verknüpften Daten unwiderruflich:")
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Aufsammlungen (Samples)", systemImage: "ant")
                        Label("Exkursionen", systemImage: "calendar")
                        Label("Fundorte", systemImage: "mappin.and.ellipse")
                        Label("Personen, Determinationen, Etiketten-PDFs", systemImage: "person.text.rectangle")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Was gelöscht wird")
                }

                Section {
                    Text(
                        """
                        Falls du deine Daten behalten willst, lade vorher unter \
                        „Einstellungen → Daten → Daten exportieren“ das ZIP-Backup \
                        herunter und sichere es an einem zuverlässigen Ort. \
                        Nach der Löschung sind die Daten unwiderruflich weg.
                        """
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Vor dem Löschen")
                }

                Section {
                    TextField("DELETE", text: $confirmation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button(role: .destructive) {
                        Task { await performDelete() }
                    } label: {
                        if busy {
                            HStack { ProgressView()
                                Text("Wird gelöscht …")
                            }
                        } else {
                            Text("Account endgültig löschen")
                        }
                    }
                    .disabled(!canDelete)
                } header: {
                    Text("Bestätigung")
                } footer: {
                    Text("Tippe das Wort DELETE ein, um den Button zu aktivieren.")
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Account löschen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(busy)
                }
            }
        }
    }

    private func performDelete() async {
        busy = true
        defer { busy = false }
        do {
            try await auth.deleteAccount()
            // On success, AuthSession clears `currentUser`, and the
            // RootView gating in FieldworksdiaryApp swaps in WelcomeView —
            // dismissing the sheet is just cosmetic.
            dismiss()
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
