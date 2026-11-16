import SwiftUI

/// Small-caps section label used throughout the app — e.g.
/// "STANDORT UND ZEIT" in the sample editor, "RECENTLY SAMPLE" in
/// the home header.
///
/// Carries the `.isHeader` accessibility trait so VoiceOver can jump
/// between sections.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.sectionHeading)
            .textCase(.uppercase)
            .foregroundStyle(AppColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Default") {
    VStack(alignment: .leading, spacing: AppSpacing.lg) {
        SectionHeader(title: "Standort und Zeit")
        SectionHeader(title: "Notizen")
        SectionHeader(title: "Active Collector")
    }
    .padding()
}
