import SwiftUI
import UIKit

/// Semantic color tokens for the app. Reads from `Assets.xcassets`
/// where we ship our own brand colours; everything else wraps
/// `UIColor` system semantics so Light/Dark/Increase-Contrast all
/// behave correctly without us having to ship per-mode hex values.
///
/// Picking the right token:
/// - **Brand** colours: the green identity (header background, FAB,
///   primary CTAs). Don't use brand colours for body text — use the
///   text tokens below.
/// - **Surface** colours: anything that's a "card" or "background".
///   Pick by elevation, not by aesthetic.
/// - **Text** tokens: body content. Default to `textPrimary`; use
///   `textSecondary`/`textTertiary` for de-emphasised text.
/// - **Status** tokens: success/warning/danger/info — for badges,
///   inline error messages, sync indicators.
///
/// Contrast notes:
///   - Light `BrandPrimary` `#1B6B2F` → contrast vs. white ≈ 6.85:1
///   - Dark  `BrandPrimary` `#3FA85A` → contrast vs. white ≈ 3.45:1
enum AppColor {
    // MARK: - Brand

    /// Primary brand colour — home header background, FAB, primary
    /// action tint. White (`brandOnPrimary`) is the only legible
    /// foreground on this surface.
    static let brandPrimary = Color("BrandPrimary")

    /// The "on" pair to `brandPrimary` — text/icons sitting on a
    /// brand surface. Always white in both colour schemes.
    static let brandOnPrimary = Color("BrandOnPrimary")

    /// Lower-emphasis variant for section headers inside the brand-
    /// coloured header (e.g. the "ACTIVE COLLECTOR" caption above
    /// the actual name).
    static let brandPrimaryMuted = Color("BrandPrimaryMuted")

    // MARK: - Surfaces
    // System wrappers — let iOS handle Light/Dark/Contrast for us.

    /// Default app background.
    static let surface = Color(uiColor: .systemBackground)

    /// One level up from `surface` — cards-on-background.
    static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)

    /// Two levels up — nested cards, modal sheets on a card.
    static let surfaceTertiary = Color(uiColor: .tertiarySystemBackground)

    /// Grouped-list backdrop (used by Settings, Home menu).
    static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)

    // MARK: - Text

    /// Default body text colour. Black/white per scheme.
    static let textPrimary = Color(uiColor: .label)

    /// Captions, supporting text.
    static let textSecondary = Color(uiColor: .secondaryLabel)

    /// Sparingly-used disabled / placeholder text.
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // MARK: - Borders / dividers

    /// The hairline divider colour matching iOS list separators.
    static let separator = Color(uiColor: .separator)

    /// Slightly stronger than `separator`; use when the divider
    /// must register at a glance (sectioned cards).
    static let outlineSubtle = Color(uiColor: .opaqueSeparator)

    // MARK: - Status
    // System semantic colours — they already adapt to Increase
    // Contrast and meet AA against system backgrounds.

    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemYellow)
    static let danger = Color(uiColor: .systemRed)
    static let info = Color(uiColor: .systemBlue)

    // MARK: - Sync state (app-specific aliases)
    // Centralised here so the four sync states stay visually consistent
    // across `SampleEditor`, `SampleDetail` and `SamplesList`.

    /// Local-only, push queued.
    static let syncPending = Color(.secondaryLabel)
    /// Push in flight.
    static let syncInFlight = Color(.secondaryLabel)
    /// Backend confirmed.
    static let syncSynced = success
    /// Last push failed; retry pending.
    static let syncFailed = warning
}
