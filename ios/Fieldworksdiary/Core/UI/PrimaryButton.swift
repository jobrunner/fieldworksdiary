import SwiftUI

/// The app's primary call-to-action button. Brand-green tint,
/// `borderedProminent` style, min-height 44pt (HIG tap target),
/// optional in-flight spinner.
///
/// Use sparingly — a screen should have at most one primary button
/// to make the main action obvious. Secondary actions go on
/// `.bordered` or plain `Button`.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                if isLoading {
                    ProgressView().tint(AppColor.brandOnPrimary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(AppFont.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColor.brandPrimary)
        .disabled(!isEnabled || isLoading)
    }
}

#Preview("States") {
    VStack(spacing: AppSpacing.md) {
        PrimaryButton(title: "Probe anlegen", systemImage: "plus") {}
        PrimaryButton(title: "Wird gespeichert …", isLoading: true) {}
        PrimaryButton(title: "GPS-Fix abwarten", isEnabled: false) {}
    }
    .padding()
}
