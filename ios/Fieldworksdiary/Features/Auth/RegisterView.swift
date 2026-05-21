import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var passwordConfirm: String = ""
    @State private var displayName: String = ""
    @State private var abbreviation: String = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-Mail", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort (min. 8 Zeichen)", text: $password)
                    SecureField("Passwort bestätigen", text: $passwordConfirm)
                }
                Section("Anzeigename") {
                    TextField("z. B. Joachim Brunner", text: $displayName)
                    TextField("Kürzel für Etiketten (z. B. J. Brunner)", text: $abbreviation)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Text(
                        """
                        Nach der Registrierung schickt das Backend eine \
                        Verifikations-E-Mail. Du kannst die App in der \
                        Zwischenzeit voll nutzen.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Konto erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Anlegen") { Task { await register() } }
                        .disabled(!canSubmit || busy)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var canSubmit: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        return !trimmedEmail.isEmpty
            && password.count >= 8
            && password == passwordConfirm
    }

    private func register() async {
        busy = true
        defer { busy = false }
        do {
            try await auth.register(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                abbreviation: abbreviation.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch let err as SampleClientError {
            error = friendly(err)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func friendly(_ err: SampleClientError) -> String {
        switch err {
        case let .http(400, body):
            if body.contains("validation_") { return "E-Mail bereits vergeben oder Passwort zu schwach." }
            return body.isEmpty ? "Registrierung abgelehnt." : body
        case let .http(s, body): return "HTTP \(s): \(body)"
        case .noEndpoint: return "Kein Backend-Endpoint gesetzt."
        case .invalidEndpoint: return "Endpoint-URL ist ungültig."
        case let .decoding(message): return "Antwort nicht lesbar: \(message)"
        }
    }
}
