import SwiftUI

/// One row in the home menu list. Icon on the left, title in the
/// middle, optional count + chevron on the right.
///
/// Rendered with `NavigationLink` from the parent so the chevron
/// behaviour and selection come for free; we just provide the visual
/// row.
///
/// Design-system note: Phase-1 refactor — the magic numbers (`16`,
/// `8`, `6`) are now `AppSpacing.lg/sm/xs`; the body font and text
/// colours come from `AppFont`/`AppColor`.
struct HomeMenuRow: View {
    let title: String
    let systemImage: String
    var count: Int? = nil

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28

    var body: some View {
        HStack(spacing: AppSpacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize * 0.7))
                .foregroundStyle(AppColor.brandPrimary)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: AppSpacing.sm)
            if let count {
                Text("\(count)")
                    .font(AppFont.body.monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(count.map { "\($0) Einträge" } ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Default") {
    VStack(spacing: 0) {
        HomeMenuRow(title: "Proben", systemImage: "photo.on.rectangle.angled", count: 12)
        Divider()
        HomeMenuRow(title: "Markierte Proben", systemImage: "star", count: 3)
        Divider()
        HomeMenuRow(title: "Einstellungen", systemImage: "gearshape")
    }
    .padding(.horizontal, AppSpacing.lg)
}
