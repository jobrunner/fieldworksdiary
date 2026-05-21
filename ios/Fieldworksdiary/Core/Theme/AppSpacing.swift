import CoreGraphics

/// 4pt-stepped spacing scale. Use these instead of literal numbers in
/// `.padding(...)`, `VStack(spacing:)`, etc. — that way changing the
/// app rhythm is a one-file edit.
///
/// Picking the right step:
/// - `xxs`/`xs`  — chip insets, tight icon-to-text gaps
/// - `sm`        — list-row vertical breathing room
/// - `md`        — default gap inside a card
/// - `lg`        — standard section padding (was `16` everywhere)
/// - `xl`        — between cards / between major sections
/// - `xxl`/`xxxl` — empty-state top padding, hero spacing
enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
