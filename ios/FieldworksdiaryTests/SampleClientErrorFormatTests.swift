@testable import Fieldworksdiary
import XCTest

/// Pins the readable rendering of PocketBase error bodies. The Apple-
/// login 400 used to show up as a raw JSON blob in the WelcomeView
/// footnote — unreadable on device. The formatter turns it into a
/// short sentence callers can actually read.
final class SampleClientErrorFormatTests: XCTestCase {
    func testAppleLoginValidationError() {
        // Real body the live backend returned for the Apple-login probe.
        let body = #"""
        {"code":400,"message":"Something went wrong while processing your request.","data":{"redirectUrl":{"code":"validation_required","message":"Cannot be blank."}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(
            out,
            "HTTP 400 — Something went wrong while processing your request. (redirectUrl: Cannot be blank.)"
        )
    }

    func testMultipleFieldErrorsAreSorted() {
        let body = #"""
        {"code":400,"message":"x","data":{"b":{"message":"second"},"a":{"message":"first"}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(out, "HTTP 400 — x (a: first · b: second)")
    }

    func testNonJSONBodyFallsBackToRaw() {
        let out = SampleClientError.formatPocketBaseError(status: 502, body: "Bad Gateway")
        XCTAssertEqual(out, "HTTP 502: Bad Gateway")
    }

    func testTopLevelMessageOnly() {
        let body = #"{"code":401,"message":"The request requires valid record authorization token to be set.","data":{}}"#
        let out = SampleClientError.formatPocketBaseError(status: 401, body: body)
        XCTAssertEqual(
            out,
            "HTTP 401 — The request requires valid record authorization token to be set."
        )
    }

    // MARK: - M-3: "Placemark" never reaches the user

    func testPlacemarkRefRejection_UsesUITerms() {
        // Body of the backend's placemark_refs hook.
        let body = #"""
        {"code":400,"message":"Invalid placemark reference.","data":{"placemark":{"code":"validation_invalid_placemark","message":"Placemark is not accessible."}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(out, "HTTP 400 — Ortsangaben ungültig. (Ortsangaben: nicht zugänglich)")
        XCTAssertNil(out.range(of: "placemark", options: .caseInsensitive))
    }

    func testSuggestionFieldKeyIsMapped() {
        let body = #"""
        {"code":400,"message":"x","data":{"placemark_suggestion":{"code":"validation_other","message":"Placemark missing."}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(out, "HTTP 400 — x (Ortsvorschlag: Ortsangaben missing.)")
    }

    func testRawBodyMentioningPlacemarkIsSanitized() {
        let out = SampleClientError.formatPocketBaseError(status: 500, body: "placemarks table locked")
        XCTAssertNil(out.range(of: "placemark", options: .caseInsensitive), out)
        XCTAssertEqual(out, "HTTP 500: Ortsangaben table locked")
    }

    func testDecodingErrorIsSanitized() {
        let out = SampleClientError.decoding("keyNotFound placemark_suggestion").errorDescription ?? ""
        XCTAssertNil(out.range(of: "placemark", options: .caseInsensitive), out)
    }
}
