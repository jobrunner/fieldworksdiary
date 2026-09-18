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
///   - `BrandPrimary` `#186029` (same in both schemes) → contrast
///     vs. white ≈ 7.65:1
///   - Light `BrandPrimaryText` `#186029` → contrast vs. white
///     background ≈ 7.31:1
///   - Dark  `BrandPrimaryText` `#6ECB86` → contrast vs. dark card
///     background ≈ 7.35:1
enum AppColor {
    // MARK: - Brand

    /// Primary brand colour used as a **surface** — home header
    /// background, FAB fill. White (`brandOnPrimary`) is the only
    /// legible foreground on this surface.
    ///
    /// `brandPrimary` and `brandPrimaryText` are deliberately two
    /// separate tokens, not one colour reused for both jobs: a fill
    /// that carries white text must stay dark in both schemes (this
    /// token is `#186029` everywhere, 7.65:1 against white), while a
    /// colour drawn as foreground on the page background must
    /// lighten in dark mode to stay legible there. The former
    /// single-role `BrandPrimary` (`#1B6B2F` light / `#3FA85A` dark)
    /// tried to serve both roles and met neither at 7:1: only 6.58:1
    /// as a light-mode fill under white text, and only 3.02:1 when
    /// the dark variant was itself used as a foreground/text colour.
    /// Do **not** use this token for text/icon foregrounds — use
    /// `brandPrimaryText`.
    static let brandPrimary = Color("BrandPrimary")

    /// Primary brand colour used as a **foreground** — icon tints,
    /// `tint`/`foregroundStyle` on brand-coloured controls, text set
    /// in the brand colour. Lightens in dark mode (`#186029` light /
    /// `#6ECB86` dark) so it keeps ≥7:1 contrast against the page
    /// background in both schemes; see `brandPrimary` above for why
    /// this can't be the same token as the surface colour.
    static let brandPrimaryText = Color("BrandPrimaryText")

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
