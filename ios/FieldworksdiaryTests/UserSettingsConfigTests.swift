@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase Z: sample-id settings in `AppConfig` and their mapping from
/// the users record.
@MainActor
final class UserSettingsConfigTests: XCTestCase {
    private let keys = [
        "AppConfig.sampleCodeTemplate", "AppConfig.sampleIDPrefix",
        "AppConfig.sampleIDOffset", "AppConfig.dayCutoffHour"
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func user(_ fields: String = "") throws -> AuthUser {
        let json = #"{"id":"u1"\#(fields)}"#
        return try JSONDecoder().decode(AuthUser.self, from: Data(json.utf8))
    }

    func testDefaults() {
        let config = AppConfig()
        XCTAssertEqual(config.sampleIDFormat, "<YY><MM><DD>/<seq>")
        XCTAssertEqual(config.sampleIDPrefix, "")
        XCTAssertEqual(config.sampleIDOffset, 0)
        XCTAssertEqual(config.dayCutoffHour, 0)
    }

    func testInvalidFormatIsNotAdopted() {
        let config = AppConfig()
        config.sampleIDFormat = "<seq>-<n>"
        XCTAssertEqual(config.sampleIDFormat, "<YY><MM><DD>/<seq>")
        config.sampleIDFormat = "<PREFIX><n>"
        XCTAssertEqual(config.sampleIDFormat, "<PREFIX><n>")
    }

    func testApplyUserRecord() throws {
        let config = AppConfig()
        config.apply(user: try user(#","sample_id_format":"<PREFIX><n>","sample_id_prefix":"JB","sample_id_offset":40,"day_cutoff_hour":4"#))
        XCTAssertEqual(config.sampleIDFormat, "<PREFIX><n>")
        XCTAssertEqual(config.sampleIDPrefix, "JB")
        XCTAssertEqual(config.sampleIDOffset, 40)
        XCTAssertEqual(config.dayCutoffHour, 4)
    }

    func testApplyEmptyOrInvalidFallsBackToDefaults() throws {
        let config = AppConfig()
        config.sampleIDFormat = "<PREFIX><n>"
        config.apply(user: try user())
        XCTAssertEqual(config.sampleIDFormat, "<YY><MM><DD>/<seq>")
        config.apply(user: try user(#","sample_id_format":"<seq><n>""#))
        XCTAssertEqual(config.sampleIDFormat, "<YY><MM><DD>/<seq>")
    }
}
