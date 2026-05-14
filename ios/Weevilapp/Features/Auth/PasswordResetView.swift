import SwiftUI

struct PasswordResetView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var busy = false
    @State private var info: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-Mail", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Passwort zurücksetzen")
                } footer: {
                    Text("Das Backend schickt einen Link an deine E-Mail. SMTP muss auf der Docker-Maschine eingerichtet sein, sonst kommt nichts an.")
                }
                if let info {
                    Section { Text(info).foregroundStyle(.secondary) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Passwort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Senden") { Task { await send() } }
                        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            try await auth.requestPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
            info = "E-Mail unterwegs (sofern die Adresse bei uns existiert)."
            error = nil
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
