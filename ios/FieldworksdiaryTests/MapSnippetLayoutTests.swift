@testable import Fieldworksdiary
import SwiftUI
import XCTest

/// Layout der Karten-Vorschau auf schmalen Bildschirmen. Mit
/// Anzeigezoom ist ein iPhone 14 nur 320 pt breit; der Snapshot
/// (600 × 260 pt) will bei 160 pt Höhe aber 369 pt. Die Vorschau darf
/// nie breiter werden als angeboten, sonst zentriert die ScrollView
/// des Sample-Editors den zu breiten Inhalt und schneidet links ab.
@MainActor
final class MapSnippetLayoutTests: XCTestCase {
    func testLoadedImageDoesNotExceedProposedWidth() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 260)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 260))
        }
        let host = UIHostingController(rootView: MapSnippetImage(image: image, height: 160))

        let proposed = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let fitted = host.sizeThatFits(in: proposed)

        XCTAssertLessThanOrEqual(fitted.width, proposed.width)
        XCTAssertEqual(fitted.height, 160, accuracy: 0.5)
    }
}
