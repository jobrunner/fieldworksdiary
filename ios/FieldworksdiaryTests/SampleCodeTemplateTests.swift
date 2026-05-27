@testable import Fieldworksdiary
import XCTest

/// R8e: the configurable sample-id template. The default must keep
/// producing the historical "YYMMDD/N" byte-for-byte, and custom
/// tokens must render as documented.
final class SampleCodeTemplateTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testDefaultReproducesCanonicalFormat() {
        let code = SampleCodeTemplate.default.format(day: day(2026, 5, 19), sequence: 7, timeZone: berlin)
        XCTAssertEqual(code, "260519/7")
    }

    func testFourDigitYearAndDashSeparator() {
        let t = SampleCodeTemplate(raw: "<YYYY><MM><DD>-<seq>")
        XCTAssertEqual(t.format(day: day(2026, 1, 3), sequence: 12, timeZone: berlin), "20260103-12")
    }

    func testSequenceFirstTemplate() {
        let t = SampleCodeTemplate(raw: "<seq>/<YY><MM><DD>")
        XCTAssertEqual(t.format(day: day(2026, 12, 31), sequence: 1, timeZone: berlin), "1/261231")
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: SampleCodeTemplate.userDefaultsKey)
        XCTAssertEqual(SampleCodeTemplate.current, .default)
    }
}
