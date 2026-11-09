import SwiftUI

/// List row for a sample: code, place name (the municipality, see
/// `PlaceDisplay.shortName`), optional note and sync badge.
///
/// Use it in every sample list (Proben, Markierte Proben, Kalender-Tag)
/// so the rows look the same. Extracted on the third repetition
/// (DESIGN-SYSTEM.md). Pass `placeName: nil` while the place is still
/// being resolved; `pendingPlaceText` is then shown in secondary style
/// (nil hides the line).
///
/// The row is one VoiceOver element; the code, place, note and sync
/// state are read in that order.
struct SampleListRow: View {
    let code: String
    let placeName: String?
    var pendingPlaceText: String?
    var notes: String = ""
    var isMarked: Bool = false
    var syncStatus: SyncStatus?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(spacing: AppSpacing.sm) {
                        star
                        codeText
                        Spacer(minLength: AppSpacing.sm)
                        badge
                    }
                    details
                }
            } else {
                HStack(spacing: AppSpacing.md) {
                    star
                    codeText
                    details
                    Spacer(minLength: AppSpacing.sm)
                    badge
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var star: some View {
        if isMarked {
            Image(systemName: "star.fill")
                .foregroundStyle(AppColor.warning)
                .accessibilityLabel("Markiert")
        }
    }

    private var codeText: some View {
        Text(code)
            .font(AppFont.codeEmphasized)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            if let placeName {
                Text(placeName)
                    .font(AppFont.subhead)
            } else if let pendingPlaceText {
                Text(pendingPlaceText)
                    .font(AppFont.subhead)
                    .foregroundStyle(AppColor.textSecondary)
            }
            if !notes.isEmpty {
                // Two lines are enough to recognise a note in a list;
                // the full text is in the editor.
                Text(notes)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let syncStatus {
            SyncStatusBadge(status: syncStatus)
        }
    }
}

private struct SampleListRowPreviewList: View {
    var body: some View {
        List {
            SampleListRow(code: "260519/1", placeName: "Ochsenfurt", notes: "Käfer an Brennnessel",
                          syncStatus: .synced)
            SampleListRow(code: "260519/2", placeName: nil, pendingPlaceText: "Ortsangaben ausstehend",
                          syncStatus: .pending)
            SampleListRow(code: "260519/3", placeName: "Garafía", isMarked: true, syncStatus: .failed)
        }
        .listStyle(.plain)
    }
}

#Preview("Default") {
    SampleListRowPreviewList()
}

#Preview("AX5") {
    SampleListRowPreviewList()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    SampleListRowPreviewList()
        .preferredColorScheme(.dark)
}
