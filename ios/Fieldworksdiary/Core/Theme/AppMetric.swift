import CoreGraphics

/// Phase-14 ad-hoc sizes. **Kept as deprecated aliases** during the
/// Design-System migration so existing call sites keep building
/// stumm. New code should use the typed scales:
///
/// - `AppSpacing.*` for padding / spacing
/// - `AppRadius.*` for corner radii
/// - Domain-specific sizes (FAB, photo thumb, menu icon) belong in
///   their owning view; they don't deserve a global token.
@available(*, deprecated, message: "Use AppSpacing / AppRadius — see .claude/rules/DESIGN-SYSTEM.md")
enum AppMetric {
    /// FAB diameter at default Dynamic Type. Apple HIG: tap targets
    /// ≥ 44pt; 64pt gives a comfortable thumb target.
    static let fabBase: CGFloat = 64

    /// Header padding around the brand block at default Dynamic
    /// Type. Replaced by `AppSpacing.xl` (24) — slightly larger
    /// because the rest of the app rhythm settled on `lg` = 16.
    static let headerVPadBase: CGFloat = AppSpacing.xl
    static let headerHPadBase: CGFloat = AppSpacing.xl

    /// Menu row icon size at default Dynamic Type.
    static let menuIconBase: CGFloat = 28

    /// Photo thumbnail size in the sample-form photo strip.
    static let photoThumbBase: CGFloat = 84
}
