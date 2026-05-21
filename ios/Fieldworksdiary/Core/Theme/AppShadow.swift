import SwiftUI

/// Drop-shadow recipes. Two roles for now — extend only when a real
/// design need shows up. Over-shadowed UIs look like 2015 Material.
struct AppShadow: Equatable {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension AppShadow {
    /// Subtle lift used for the home FAB, primary cards-on-background.
    /// Just enough to register, not so much it bleeds onto neighbours.
    static let card = AppShadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)

    /// Larger lift for floating overlays — popovers, attention-
    /// drawing badges, anything that must clearly sit above content.
    static let elevated = AppShadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 4)
}

extension View {
    /// `.appShadow(.card)` — applies one of the AppShadow recipes
    /// without each caller having to remember the offsets.
    func appShadow(_ s: AppShadow) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
