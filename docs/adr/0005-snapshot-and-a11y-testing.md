# ADR 0005: iOS-Test-Stack — Unit, Snapshot, Accessibility-Audit, MetricKit

**Datum:** 2026-05-16
**Status:** akzeptiert
**Kontext:** Pre-App-Store-Submit, Test-Pyramide aufbauen

## Entscheidung

Vier Test-/Telemetrie-Ebenen, alle Apple-nativ oder mit minimaler
externer Abhängigkeit:

1. **Unit-Tests** mit XCTest im Target `FieldworksdiaryTests`. Decken
   isolierbare Logik ab (`CodesTests`, `ExcursionsFilterTests`).
   Mindest-Coverage-Anforderung: keine harte Grenze auf iOS-Seite
   (Backend hat > 80 % auf Kern-Packages); für iOS gilt:
   neue Features mit nicht-trivialer Logik kriegen mindestens einen
   Happy-Path-Test.

2. **Snapshot-Tests** via `pointfreeco/swift-snapshot-testing` ab
   Version 1.17.0, ebenfalls im Target `FieldworksdiaryTests`. Aktuell
   ein Smoketest (`SnapshotsTests.testPrimaryButton`); Snapshots
   liegen unter `FieldworksdiaryTests/__Snapshots__/` und werden
   committed. Erster Run zeichnet auf, Folgeläufe vergleichen.

3. **Accessibility-Audit** im neuen Target `FieldworksdiaryUITests`
   (`bundle.ui-testing`). Nutzt Apples `XCUIApplication.performAccessibilityAudit()`
   (iOS 17+, Xcode 15+) zur Laufzeit-Prüfung von Hit-Region, Element-
   Detection, Trait-Konflikten und Sufficient-Element-Description.
   Aktuell kategorien-eingeschränkt: `contrast`, `dynamicType` und
   `textClipped` sind ausgeklammert, bis es einen UX-Pass für
   Farb-Tokens und AX-Schrift-Layouts gegeben hat (TODO im Test
   kommentiert).

4. **MetricKit** als Production-Telemetrie für Crashes, Hangs,
   CPU- und Disk-Exceptions. `MetricsReporter` (in
   `Core/Observability/MetricsReporter.swift`) registriert sich
   beim App-Bootstrap und loggt eingehende Payloads via
   `Log.metrics`. Reports sichtbar im Xcode-Organizer und im
   OSLog-Stream.

## Alternativen, die wir verworfen haben

- **Sentry / Firebase Crashlytics**: leisten mehr als MetricKit
  (Symbolisierung, Such-UI, Email-Alerts), aber Drittanbieter,
  Telemetrie verlässt das Gerät, separate Privacy-Manifest-Einträge
  nötig. Für Solo-Dev mit Phase-1-App ist MetricKit „good enough".
  Re-evaluate, wenn die App > 100 Tester oder erste Prod-User hat.

- **Self-Rolling Snapshot-Tests** mit `XCTAttachment(image:)`:
  funktioniert, aber kein Diff-Vergleich. `swift-snapshot-testing`
  ist battle-tested, gut gepflegt, weite Community-Verbreitung.

- **Nur SwiftLint-A11y-Rules** (`accessibility_label_for_image`,
  `accessibility_trait_for_button`): statisch, fängt etwa 10 % der
  realen A11y-Probleme. Runtime-Audit deckt die anderen 90 % —
  hat in Phase 1 sofort einen echten Hit-Region-Bug auf der
  Welcome-View gefunden.

- **Eigenes UI-Test-Framework**: nope. XCTest+XCUITest ist Standard.

## Konsequenzen

- Drei iOS-Targets (App, Tests, UI-Tests) im `project.yml`. UI-Tests
  brauchen `bundle.ui-testing`-Type und eigene Bundle-ID
  (`org.fieldworksdiary.dev.uitests`).

- CI-Workflow `ios.yml` läuft `xcodebuild test` über das gemeinsame
  Scheme `Fieldworksdiary` — beide Test-Targets laufen mit.

- Snapshot-Pixel-Vergleiche sind Simulator-spezifisch. Wenn der
  GitHub-Actions-Runner einen anderen Simulator-Stand hat als die
  lokale Maschine, kann ein Snapshot diffen. Mitigation: wir
  pinnen Frame-Size + `fixedSize()` explizit, das macht den Snapshot
  Geräte-unabhängiger als ein voller View-Hierarchy-Capture.

- Crash-Telemetrie via MetricKit kommt mit **24-h-Latenz**: Apple
  sammelt auf dem Gerät, liefert beim nächsten Start aus.
  Konsequenz: nach Release einige Tage warten, bevor man entscheidet,
  ob ein Build stabil ist.

## Referenzen

- Tests: `ios/FieldworksdiaryTests/SnapshotsTests.swift`,
  `ios/FieldworksdiaryUITests/AccessibilityAuditTests.swift`.
- Konfig: `ios/project.yml` (Targets und Schemes),
  `.swiftlint.yml` (Accessibility-Opt-in-Regeln).
- Reporter: `ios/Fieldworksdiary/Core/Observability/MetricsReporter.swift`.
- Regel-Dateien: `.claude/rules/ACCESSIBILITY-IOS.md`,
  `.claude/rules/LOGGING.md`.
