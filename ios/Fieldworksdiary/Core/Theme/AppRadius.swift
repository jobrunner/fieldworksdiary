import CoreGraphics

/// Corner-radius scale. Pick the smallest that still reads as
/// "rounded" — over-rounded UIs cost vertical real estate without
/// adding meaning.
///
/// - `sm`    — thumbnails, small chips
/// - `md`    — default card corners
/// - `lg`    — brand-coloured header, FAB background
/// - `xl`    — sheet handles, hero artwork
/// - `pill`  — fully-rounded capsule (any height, will fully round)
enum AppRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let pill: CGFloat = 999
}
