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
    private let size = CGSize(width: 320, height: 64)

    func testPrimaryButton() {
        let view = PrimaryButtonPreview()
            .frame(width: size.width, height: size.height)
            .fixedSize()

        // Precision-Toleranzen erlauben kleine Pixel-Diffs zwischen
        // Renderer-Versionen (lokales Xcode ≠ CI-Xcode/-Simulator).
        // 0.99/0.97 sind die Point-Free-Empfehlungen für stabile
        // SwiftUI-Smoketests; höhere Werte führen zu Flakiness.
        assertSnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: size.width, height: size.height)
            )
        )
    }
}

/// Klein gehaltene Vorschau-Komponente — bewusst minimal, damit der
/// Smoketest nicht durch Änderungen an echten Views flackert.
private struct PrimaryButtonPreview: View {
    var body: some View {
        Button {
            // intentional no-op
        } label: {
            Label("Sample anlegen", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .accessibilityIdentifier("primary-button-preview")
    }
}
