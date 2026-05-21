import SwiftUI

/// Generic card surface — a rounded rectangle with the app's default
/// background colour and inner padding. Use this instead of
/// `GroupBox` when you want the design-system look (corner radius
/// from `AppRadius.md`, padding from `AppSpacing.lg`).
///
/// Composition over inheritance: `AppCard` itself doesn't know about
/// its content. Pass any view — header, value rows, buttons — and
/// the card just provides the visual frame.
struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

#Preview("Default") {
    VStack(spacing: AppSpacing.md) {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                SectionHeader(title: "Notizen")
                Text("Käfer an Brennnessel, sonnig, leichter Wind.")
                    .font(AppFont.body)
            }
        }
        AppCard {
            HStack {
                Text("Code")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
                Text("260521/3")
                    .font(AppFont.codeEmphasized)
            }
        }
    }
    .padding()
    .background(AppColor.surface)
}
