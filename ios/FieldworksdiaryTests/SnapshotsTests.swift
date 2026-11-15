@testable import Fieldworksdiary
import SnapshotTesting
import SwiftUI
import XCTest

/// Beispiel-Snapshot-Test als Smoketest für die Snapshot-Pipeline.
/// Konzept (siehe pointfree.co/swift-snapshot-testing):
///   - Erster Run: legt eine Referenz unter __Snapshots__/ an,
///     gilt als „record OK" → Test grün.
///   - Folgende Runs: vergleicht gerenderten View gegen Referenz; bei
///     Diff wird der Test rot und der Diff-PNG-Pfad gemeldet.
///
/// **Refresh** (z. B. nach absichtlichem UI-Change):
///   `isRecording = true` im Test setzen, einmal laufen lassen,
///   Flag wieder entfernen. ODER über Schema-Env-Var
///   `SNAPSHOT_TESTING_RECORD=true` global.
///
/// **Tests laufen auch ohne Snapshots**: beim ersten Run werden die
/// Bilder erzeugt und der Test ist grün. Auf einem CI-Runner ohne
/// committeten Snapshot würde das ebenfalls grün — daher Snapshots
/// **immer committen**, damit Regressions ab dem zweiten Run greifen.
final class SnapshotsTests: XCTestCase {
    /// Stabile Render-Konfiguration: fixe Größe, fixer Trait-Stack.
    /// Verhindert Flackern durch Simulator-Variationen.
    private let size = CGSize(width: 320, height: 80)

    func testPrimaryButton() {
        let view = PrimaryButton(title: "Sample anlegen", systemImage: "plus.circle.fill") {}
            .padding()
            .frame(width: size.width, height: size.height)
            .fixedSize()

        // Eine Referenz pro iOS-Hauptversion: `borderedProminent` hat
        // unter iOS 18 und iOS 26 andere Innenabstände und Schrift-
        // metrik, ein gemeinsames Bild wäre auf einer Seite immer rot.
        // Precision-Toleranzen fangen nur kleine Renderer-Diffs ab
        // (lokales Xcode ≠ CI-Xcode); 0.99/0.97 sind die Point-Free-
        // Empfehlungen für stabile SwiftUI-Smoketests.
        assertSnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: size.width, height: size.height)
            ),
            named: "iOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        )
    }
}
