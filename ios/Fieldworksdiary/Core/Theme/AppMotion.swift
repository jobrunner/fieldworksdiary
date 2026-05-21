import SwiftUI

/// Animation defaults. Use one of these instead of bespoke
/// `.easeInOut(duration: 0.25)`-style literals — that way a tweak to
/// the app's overall feel touches one file.
enum AppMotion {
    /// Micro-feedback (icon flip, badge toggle). Under 200ms so the
    /// motion never gets in the way of input.
    static let fast: Animation = .easeInOut(duration: 0.15)

    /// Default for state transitions (sheet open, list refresh).
    static let base: Animation = .easeInOut(duration: 0.25)

    /// Slower change for context shifts the user *should* notice
    /// (e.g. switching screens, large layout changes).
    static let slow: Animation = .easeInOut(duration: 0.4)

    /// Spring for natural button presses, FAB tap, drag-snap.
    static let spring: Animation = .interpolatingSpring(stiffness: 220, damping: 18)

    /// Wraps an animation with the user's Reduce-Motion setting in
    /// mind. Pass the env value from
    /// `@Environment(\.accessibilityReduceMotion)` and use the result
    /// directly in `.animation(...)`.
    ///
    ///     @Environment(\.accessibilityReduceMotion) private var rm
    ///     .animation(AppMotion.respecting(.base, reduceMotion: rm), value: state)
    static func respecting(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
