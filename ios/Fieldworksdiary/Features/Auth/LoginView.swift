import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
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
                    SecureField("Passwort", text: $password)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Anmelden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Anmelden") { Task { await login() } }
                        .disabled(!canSubmit || busy)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
            !password.isEmpty
    }

    private func login() async {
        busy = true
        defer { busy = false }
        do {
            try await auth.signInWithPassword(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
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
        case .http(400, _): return "E-Mail oder Passwort nicht erkannt."
        case let .http(s, body): return "HTTP \(s): \(body)"
        case .noEndpoint: return "Kein Backend-Endpoint gesetzt."
        case .invalidEndpoint: return "Endpoint-URL ist ungültig."
        case let .decoding(message): return "Antwort nicht lesbar: \(message)"
        }
    }
}
