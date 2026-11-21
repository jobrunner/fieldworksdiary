@testable import Legulus
import XCTest

/// Die Dienste eines Kontos dürfen nie mit dem Token eines anderen
/// Kontos sprechen, auch wenn sich inzwischen jemand anderes anmeldet.
final class AccountBoundAuthTests: XCTestCase {
    private final class Source: AuthTokenSource {
        var currentToken: String?
    }

    /// Ein Token im PocketBase-Format (JWT) für den angegebenen Nutzer.
    private func token(userID: String) throws -> String {
        func part(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try part(["alg": "HS256", "typ": "JWT"]) + "."
            + part(["id": userID, "type": "auth", "collectionId": "_pb_users_auth_", "exp": 1_900_000_000])
            + ".signature"
    }

    func testTokenOfTheOwnAccountIsPassedOn() throws {
        let source = Source()
        source.currentToken = try token(userID: "usera0000000001")
        let bound = AccountBoundAuth(source: source, accountID: "usera0000000001")
        XCTAssertEqual(bound.currentToken, source.currentToken)
    }

    func testTokenOfAnotherAccountIsWithheld() throws {
        let source = Source()
        source.currentToken = try token(userID: "userb0000000002")
        let bound = AccountBoundAuth(source: source, accountID: "usera0000000001")
        XCTAssertNil(bound.currentToken, "Konto A darf nie mit dem Token von Konto B sprechen")
    }

    /// The same bound object over time: A signs out, B signs in.
    func testFollowsTheSessionOverTime() throws {
        let source = Source()
        let bound = AccountBoundAuth(source: source, accountID: "usera0000000001")
        source.currentToken = try token(userID: "usera0000000001")
        XCTAssertNotNil(bound.currentToken)
        source.currentToken = nil
        XCTAssertNil(bound.currentToken)
        source.currentToken = try token(userID: "userb0000000002")
        XCTAssertNil(bound.currentToken)
        source.currentToken = try token(userID: "usera0000000001")
        XCTAssertNotNil(bound.currentToken)
    }

    func testUnreadableTokenIsWithheld() {
        let source = Source()
        let bound = AccountBoundAuth(source: source, accountID: "usera0000000001")
        for raw in ["", "kein-jwt", "a.b", "a.%%%.c", "a.e30.c"] {
            source.currentToken = raw
            XCTAssertNil(bound.currentToken, raw)
        }
    }

    func testTokenUserID() throws {
        XCTAssertEqual(try AccountBoundAuth.userID(ofToken: token(userID: "usera0000000001")), "usera0000000001")
        XCTAssertNil(AccountBoundAuth.userID(ofToken: "x.y.z"))
    }
}
