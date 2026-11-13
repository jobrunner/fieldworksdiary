@testable import Fieldworksdiary
import FieldworksGeo
import Foundation
import XCTest

final class OrtusClientInputTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
        nonisolated(unsafe) static var lastURL: URL?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lastURL = request.url
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (status, data) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient() -> OrtusClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return OrtusClient(endpoint: "https://ortus.test", session: URLSession(configuration: config))
    }

    private let utm = CoordinateInput(system: .etrs89utm32, first: "574400", second: "5503700")

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastURL = nil
    }

    func testBuildsRequestAndDecodes() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"wgs84":{"lat":49.68123,"lon":10.03134}}"#.utf8)) }
        let response = try await makeClient().query(input: utm)
        XCTAssertEqual(response.wgs84?.lat, 49.68123)
        let items = try URLComponents(url: XCTUnwrap(StubProtocol.lastURL), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["srid", "x", "y"])
        XCTAssertEqual(StubProtocol.lastURL?.path, "/api/v1/query")
    }

    func testEmptyBodyIsNoWGS84() async {
        StubProtocol.handler = { _ in (200, Data()) }
        await assertThrows(.noWGS84)
    }

    func testMissingWGS84IsNoWGS84() async {
        StubProtocol.handler = { _ in (200, Data("{}".utf8)) }
        await assertThrows(.noWGS84)
    }

    func testBadRequestCarriesMessage() async {
        let body = #"{"error":"Bad Request","message":"mgrs: invalid input: x"}"#
        StubProtocol.handler = { _ in (400, Data(body.utf8)) }
        await assertThrows(.server(message: "mgrs: invalid input: x"))
    }

    func testServerErrorWithoutJSONHasNoMessage() async {
        StubProtocol.handler = { _ in (502, Data("oops".utf8)) }
        await assertThrows(.server(message: nil))
    }

    func testOffline() async {
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await assertThrows(.offline)
    }

    func testInvalidInputThrowsBeforeRequest() async {
        StubProtocol.handler = { _ in XCTFail("no request expected")
            return (200, Data())
        }
        do {
            _ = try await makeClient().query(input: CoordinateInput(system: .gk2, first: "", second: ""))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? CoordinateInputError, .invalidNumber)
        }
    }

    func testUserMessages() {
        XCTAssertEqual(OrtusQueryError.offline.userMessage, "Keine Verbindung zu Ortus. Bitte später erneut versuchen.")
        XCTAssertEqual(OrtusQueryError.server(message: "m").userMessage, "Ortus konnte die Koordinate nicht umrechnen: m")
        XCTAssertEqual(OrtusQueryError.server(message: nil).userMessage, "Ortus konnte die Koordinate nicht umrechnen.")
    }

    private func assertThrows(_ expected: OrtusQueryError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await makeClient().query(input: utm)
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OrtusQueryError, expected, file: file, line: line)
        }
    }
}
