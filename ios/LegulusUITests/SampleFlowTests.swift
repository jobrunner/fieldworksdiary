import CoreLocation
import XCTest

/// Anmeldung und Probe anlegen gegen die Test-Instanz, mit simuliertem
/// Standort. Die angelegte Probe räumt der Test selbst wieder ab.
final class SampleFlowTests: XCTestCase {
    /// Simulierter Standort (bei Ochsenfurt), auf 2 Nachkommastellen
    /// im Test geprüft.
    private let simulatedLocation = CLLocation(latitude: 49.681, longitude: 10.0406)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Anmeldung über das Login-Formular. Der Test endet mit der
    /// Startansicht und bedient sie nicht: iOS 26 legt kurz danach
    /// „Passwort sichern?“ darüber.
    @MainActor
    func testLoginWithTestUser() {
        let app = TestBackend.launchApp()
        let openLogin = app.buttons["Mit E-Mail anmelden"]
        XCTAssertTrue(openLogin.waitForExistence(timeout: 10), "Welcome-Screen erscheint nicht")
        openLogin.tap()

        let email = app.textFields["E-Mail"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText(TestBackend.email)
        let password = app.secureTextFields["Passwort"]
        password.tap()
        password.typeText(TestBackend.password)
        app.navigationBars["Anmelden"].buttons["Anmelden"].tap()

        XCTAssertTrue(
            app.buttons["Neue Probe anlegen"].waitForExistence(timeout: 15),
            "Nach der Anmeldung erscheint die Startansicht nicht"
        )
    }

    @MainActor
    func testAddSampleWithSimulatedLocation() {
        XCUIDevice.shared.location = XCUILocation(location: simulatedLocation)
        let app = TestBackend.launchApp(signedIn: true, resetLocationPermission: true)
        let addSample = app.buttons["Neue Probe anlegen"]
        XCTAssertTrue(addSample.waitForExistence(timeout: 15), "Startansicht erscheint nicht")

        addSample.tap()
        allowLocationIfAsked(timeout: 5)

        let codeField = app.textFields["Sample-Code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "Sample-Editor erscheint nicht")
        let coordinate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '49.68'")).firstMatch
        XCTAssertTrue(coordinate.waitForExistence(timeout: 30), "Simulierte Koordinate erscheint nicht")

        allowLocationIfAsked(timeout: 3)

        // Abräumen: eine neue Probe mit leerer ID lässt sich beim
        // Zurückgehen löschen. Steht schon ein Code im Feld, wird er
        // vorher geleert.
        let code = codeField.value as? String ?? ""
        if !code.isEmpty {
            // Erst fokussieren, dann den Cursor ans Ende setzen: ein
            // Tap rechts neben den Text fokussiert unter iOS 26 nicht.
            codeField.tap()
            codeField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            codeField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: code.count))
        }
        app.buttons["Zurück"].tap()
        let delete = app.alerts.buttons["Sample löschen"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Dialog zur leeren Sample-ID erscheint nicht")
        delete.tap()
        XCTAssertTrue(app.buttons["Neue Probe anlegen"].waitForExistence(timeout: 10))
    }

    // MARK: - helpers

    /// Bestätigt eine Standort-Abfrage des Systems, falls eine kommt.
    /// Die App fragt zweimal: erst „Beim Verwenden“, nach dem ersten
    /// Fix die Erweiterung auf „Immer“. In beiden Dialogen erlaubt der
    /// zweite Button den Zugriff; der Index statt des Texts hält den
    /// Test von der Simulator-Sprache unabhängig.
    @MainActor
    private func allowLocationIfAsked(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        let buttons = alert.buttons
        if buttons.count >= 2 {
            buttons.element(boundBy: 1).tap()
        }
        _ = alert.waitForNonExistence(timeout: 3)
    }
}
