import SwiftUI

/// The big green block at the top of the home dashboard. Combines
/// active-collector / active-fieldtrip / recently-sample with the
/// primary "+" action.
///
/// A11y notes:
///   - Section labels (ACTIVE COLLECTOR …) carry `.isHeader`; VoiceOver
///     announces them as headings so users can jump between them.
///   - Each label/value pair is `.accessibilityElement(children: .combine)`
///     so VoiceOver reads "Aktiver Sammler J.Brunner" as one element.
///   - The FAB is at least 64×64pt (HIG ≥ 44pt) with an explicit
///     `.accessibilityLabel` + `.accessibilityHint`.
///   - The whole layout switches to a vertical stack on accessibility
///     Dynamic Type sizes via `ViewThatFits`.
struct HomeHeader: View {
    let collectorName: String
    let activeFieldtrip: HomeViewModel.ActiveFieldtrip?
    let recentSample: HomeViewModel.RecentSample?
    let onAddSample: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // FAB-Größe ist domänenspezifisch (Heim-Dashboard) — kein
    // globales Spacing-Token, sondern ein lokales `@ScaledMetric`.
    @ScaledMetric(relativeTo: .title) private var fabSize: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var hPad: CGFloat = AppSpacing.xl
    @ScaledMetric(relativeTo: .body) private var vPad: CGFloat = AppSpacing.xl

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.brandPrimary)
        .foregroundStyle(AppColor.brandOnPrimary)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            infoColumn
            Spacer(minLength: 0)
            fab
                .accessibilitySortPriority(1) // surface the FAB first
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            infoColumn
            HStack { Spacer()
                fab
            }
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            field(label: "Aktiver Sammler", value: collectorName.isEmpty ? "—" : collectorName)
            field(
                label: "Aktive Exkursion",
                value: activeFieldtrip?.title ?? "Keine aktive Exkursion",
                detail: activeFieldtrip?.localityName
            )
            field(
                label: "Letzte Probe",
                value: recentSample?.code ?? "—",
                detail: recentSample?.locality
            )
        }
    }

    private func field(label: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(label.uppercased())
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.brandPrimaryMuted)
                .accessibilityAddTraits(.isHeader)
            // Field-Value-Role gibt's in AppFont noch nicht — die
            // Größe (~title3) sitzt zwischen `headline` und
            // `sectionTitle`. Bei der dritten Wiederholung extrahieren
            // wir das in AppFont (Drei-Wiederholungen-Regel).
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColor.brandOnPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.subhead)
                    .foregroundStyle(AppColor.brandPrimaryMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fab: some View {
        Button(action: onAddSample) {
            Image(systemName: "plus")
                .font(.system(size: fabSize * 0.45, weight: .bold))
                .foregroundStyle(AppColor.brandPrimary)
                .frame(width: fabSize, height: fabSize)
                .background(
                    Circle()
                        .fill(AppColor.brandOnPrimary)
                        .shadow(radius: 2, y: 1)
                )
        }
        .accessibilityLabel("Neue Probe anlegen")
        .accessibilityHint("Öffnet das Formular zur Erfassung einer Probe mit Foto und Notizen.")
        .accessibilityAddTraits(.isButton)
    }
}
