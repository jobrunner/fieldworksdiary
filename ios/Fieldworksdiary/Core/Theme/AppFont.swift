import SwiftUI

/// Semantic typography roles. Each role is built on a Dynamic-Type
/// style so the user's text-size preference is always respected.
///
/// Rule of thumb: pick by **role** (`AppFont.sectionTitle`), not by
/// size (`Font.title2`). When in doubt about which role to use, look
/// at the Design Catalog (Debug → Settings → Design-Katalog).
enum AppFont {
    // MARK: - Display

    /// 34pt @ default. Used by hero text and the few standalone
    /// numeric displays (e.g. the sample code on the success card).
    static let screenTitle = Font.largeTitle.weight(.bold)

    // MARK: - Sections

    /// 22pt. Top-of-section headings inside a screen.
    static let sectionTitle = Font.title2.weight(.semibold)

    /// 12pt SMALL-CAPS-stil — used for the all-caps category labels
    /// like "STANDORT UND ZEIT". Use `.textCase(.uppercase)` on the
    /// containing Text when you want the visual.
    static let sectionHeading = Font.caption.weight(.semibold)

    // MARK: - Body

    static let headline = Font.headline
    static let body = Font.body
    static let bodyEmphasized = Font.body.weight(.semibold)
    static let callout = Font.callout
    static let subhead = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
    static let captionEmphasized = Font.caption.weight(.semibold)

    // MARK: - Monospaced (sample codes, coordinates)

    static let code = Font.body.monospaced()
    static let codeEmphasized = Font.body.monospaced().weight(.semibold)
    /// Used for the headline sample code on the editor's success card.
    static let codeLarge = Font.system(.largeTitle, design: .monospaced).weight(.bold)
}
