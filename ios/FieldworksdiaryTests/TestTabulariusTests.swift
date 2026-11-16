@testable import Fieldworksdiary
import XCTest

/// Eingebackener Endpoint im Simulator und Erreichbarkeit der
/// Test-Instanz (docker-compose.test.yml).
final class TestTabulariusTests: XCTestCase {
    private var bakedEndpoint: String {
        Bundle.main.object(forInfoDictionaryKey: "TABULARIUS_ENDPOINT_DEFAULT") as? String ?? ""
    }

    /// Debug nimmt im Simulator die Dev-Instanz (8090), Test die
    /// Test-Instanz (8092) - nie den Tunnel.
    func testSimulatorBuildDefaultsToLocalhost() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("Auf dem Gerät bleibt der eingebackene Endpoint (Tunnel).")
        #endif
        XCTAssertTrue(
            bakedEndpoint.hasPrefix("http://localhost:"),
            "Eingebackener Endpoint im Simulator: \(bakedEndpoint)"
        )
    }

    /// Nur im Scheme `Fieldworksdiary-Test` („Legulus Test“): dort muss
    /// die Test-Instanz laufen. Die Pre-Action des Schemes setzt sie
    /// auf, kann den Lauf aber nicht abbrechen - das macht dieser Test.
    func testTestInstanceIsReachable() async throws {
        try XCTSkipUnless(
            Bundle.main.bundleIdentifier == "app.legulus.test",
            "Läuft nur im Scheme Fieldworksdiary-Test."
        )
        let url = try XCTUnwrap(URL(string: bakedEndpoint + "/api/health"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
