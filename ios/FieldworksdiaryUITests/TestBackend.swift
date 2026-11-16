import XCTest

/// Test-Instanz von Tabularius und ihr fester Test-Nutzer. Die Instanz
/// setzt `scripts/reset-test-tabularius.sh` vor jedem Testlauf neu auf;
/// die Zugangsdaten stehen auch dort - beide Stellen zusammen ändern.
enum TestBackend {
    static let endpoint = "http://localhost:8092"
    static let email = "uitest@legulus.example"
    static let password = "legulus-uitest-1"

    /// Startet die App mit der Test-Instanz als Endpoint. UserDefaults
    /// liest `-<key> <value>` aus den Argumenten, ein früher
    /// gespeicherter Endpoint zählt damit nicht.
    ///
    /// Ohne `signedIn` startet die App abgemeldet. Mit `signedIn`
    /// meldet sie sich beim Start selbst als Test-Nutzer an, ohne das
    /// Login-Formular: nach einer Eingabe ins Passwortfeld bietet
    /// iOS 26 „Passwort sichern?“ an, und dieses System-Sheet legt
    /// sich verzögert über den weiteren Testablauf.
    @MainActor
    static func launchApp(signedIn: Bool = false, resetLocationPermission: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if resetLocationPermission {
            app.resetAuthorizationStatus(for: .location)
        }
        app.launchArguments += ["-UITests", "true"]
        app.launchArguments += ["-UITestsSignedOut", "true"]
        if signedIn {
            app.launchArguments += ["-UITestsSignInEmail", email, "-UITestsSignInPassword", password]
        }
        app.launchArguments += ["-AppConfig.endpointURL", endpoint]
        app.launch()
        return app
    }
}
