import CoreGraphics

/// Z-index constants for `ZStack` layering. Use the named layer
/// instead of bare numbers — that way "this overlay goes above
/// content but below sheets" is obvious at the call site.
enum AppZIndex {
    static let background: Double = 0
    static let content: Double = 10
    static let overlay: Double = 100
    static let sheet: Double = 1000
}
