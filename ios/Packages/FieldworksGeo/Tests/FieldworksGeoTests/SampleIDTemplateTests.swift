@testable import FieldworksGeo
import XCTest

final class SampleIDTemplateTests: XCTestCase {
    func testInvalidWithBothCounters() {
        XCTAssertFalse(SampleIDTemplate(raw: "<YY><MM><DD>/<seq><n>").isValid)
        XCTAssertTrue(SampleIDTemplate.default.isValid)
    }

    func testCounterKinds() {
        XCTAssertEqual(SampleIDTemplate.default.counter, .daily)
        XCTAssertEqual(SampleIDTemplate(raw: "<PREFIX><n>").counter, .running)
        XCTAssertEqual(SampleIDTemplate(raw: "X<YY>").counter, .none)
    }

    func testRender() {
        XCTAssertEqual(SampleIDTemplate.empty.render(day: "2026-01-15", prefix: "", number: 3), "")
        XCTAssertEqual(SampleIDTemplate.default.render(day: "2026-01-15", prefix: "", number: 3), "260115/3")
        XCTAssertEqual(SampleIDTemplate(raw: "<YYYY><MM><DD>/<seq>").render(day: "2026-01-15", prefix: "", number: 3), "20260115/3")
    }

    func testPresets() {
        XCTAssertEqual(SampleIDTemplate.presets.count, 6)
        XCTAssertEqual(SampleIDTemplate.presets.last, .empty)
    }

    func testEmptySuggestion() {
        let r = SampleIDTemplate.nextSuggestion(template: .empty, prefix: "", day: "2026-01-15",
                                                existingIDs: [], lastRunning: 0, offset: 0)
        XCTAssertEqual(r.id, "")
        XCTAssertNil(r.running)
    }

    func testRunning() {
        let t = SampleIDTemplate(raw: "<PREFIX><n>")
        var r = SampleIDTemplate.nextSuggestion(template: t, prefix: "JB-", day: "2026-01-15",
                                                existingIDs: [], lastRunning: 0, offset: 1000)
        XCTAssertEqual(r.id, "JB-1001")
        XCTAssertEqual(r.running, 1001)
        r = SampleIDTemplate.nextSuggestion(template: t, prefix: "JB-", day: "2026-01-15",
                                            existingIDs: ["JB-1001"], lastRunning: 0, offset: 1000)
        XCTAssertEqual(r.id, "JB-1002")
        XCTAssertEqual(r.running, 1002)
    }

    func testDaily() {
        let t = SampleIDTemplate.default
        var r = SampleIDTemplate.nextSuggestion(template: t, prefix: "", day: "2026-01-15",
                                                existingIDs: ["260115/1", "260115/2"], lastRunning: 0, offset: 0)
        XCTAssertEqual(r.id, "260115/3")
        XCTAssertNil(r.running)
        r = SampleIDTemplate.nextSuggestion(template: t, prefix: "", day: "2026-01-15",
                                            existingIDs: ["260114/7", "260115/2 (2)"], lastRunning: 0, offset: 0)
        XCTAssertEqual(r.id, "260115/1")
    }

    func testDailyReverseTemplateEscapes() {
        let t = SampleIDTemplate(raw: "<seq>/<YY><MM><DD>")
        let r = SampleIDTemplate.nextSuggestion(template: t, prefix: "", day: "2026-01-15",
                                                existingIDs: ["4/260115", "9/260116"], lastRunning: 0, offset: 0)
        XCTAssertEqual(r.id, "5/260115")
    }
}
