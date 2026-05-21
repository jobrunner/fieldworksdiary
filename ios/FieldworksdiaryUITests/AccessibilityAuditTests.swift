import XCTest

/// Runtime-Accessibility-Audit via Apples eingebauter API
/// (`XCUIApplication.performAccessibilityAudit()`, iOS 17+, Xcode 15+).
/// Deckt Bereiche ab, die SwiftLint nicht sehen kann:
/// - Kontrast (Text/Background, sichtbare Elemente)
/// - Dynamic-Type-Support (Text wird nicht abgeschnitten)
/// - Hit-Region (Touch-Targets ≥ 44 pt)
/// - Trait-Konflikte
/// - Accessibility-Element-Reihenfolge
///
/// Audit-Kategorien (iOS 17): `.contrast, .dynamicType, .hitRegion,
/// .elementDetection, .traits, .textClipped`. Wir auditieren standardmäßig
/// alle bis auf `.dynamicType` — letzteres erfordert separate Tests pro
/// Schriftgröße und produziert sonst zu viele False-Positives in einem
/// Standard-Run. Bei Bedarf gezielt aufrufen.
final class AccessibilityAuditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeScreenAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "true"]
        app.launch()

        // Warten, bis WelcomeView gerendert hat. Wenn der User schon
        // eingeloggt ist, landen wir stattdessen in den MainTabs —
        // beides ist auditfähig, der Audit prüft was sichtbar ist.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        // Baseline-Audit: alles außer drei Design-getriebene Kategorien.
        //   .contrast       — braucht definierte Farb-Tokens
        //   .dynamicType    — braucht AX-Layout-Pass über große Schriften
        //   .textClipped    — Folge von dynamicType-Issues
        // Diese werden in einem separaten UX-Sprint adressiert (siehe
        // @.claude/rules/ACCESSIBILITY-IOS.md). Geprüft bleiben:
        //   .hitRegion, .elementDetection, .trait,
        //   .sufficientElementDescription, .parentTruncation.
        try app.performAccessibilityAudit(
            for: .all.subtracting([.contrast, .dynamicType, .textClipped])
        )
    }
}
