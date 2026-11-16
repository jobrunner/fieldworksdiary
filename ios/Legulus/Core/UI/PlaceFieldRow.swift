import SwiftUI

/// One place field of a sample or locality (Phase O2): the
/// country-specific term on top (e.g. „Landkreis“, „Provincia“), the
/// generic type below it (e.g. „Kreis“) and the value.
///
/// Use it for every Ortus place field (admin levels, island, mountain
/// range, mountain) so all screens label places the same way. When the
/// country has no own term, pass `term: nil`: the generic type moves
/// up and is not repeated.
///
/// Layout: label column and value side by side; on accessibility text
/// sizes (or when the value doesn't fit) the value moves below the
/// labels. VoiceOver reads one element: „<Landesbegriff>: <Wert>“,
/// with the generic type as hint when it differs from the term.
struct PlaceFieldRow: View {
    let term: String?
    let genericLabel: String
    let value: String

    init(term: String?, genericLabel: String, value: String) {
        self.term = term
        self.genericLabel = genericLabel
        self.value = value
    }

    init(_ item: PlaceFieldItem) {
        self.init(term: item.term, genericLabel: item.genericLabel, value: item.value)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var topLabel: String {
        term ?? genericLabel
    }

    /// Generic type shown under the term only when it adds something.
    private var subLabel: String? {
        guard let term, term.caseInsensitiveCompare(genericLabel) != .orderedSame else { return nil }
        return genericLabel
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    sideBySide
                    stacked
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(topLabel): \(value)")
        .accessibilityHint(subLabel ?? "")
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(topLabel)
                .font(AppFont.subhead)
                .foregroundStyle(AppColor.textPrimary)
            if let subLabel {
                Text(subLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
    }

    private var sideBySide: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            labels
            Spacer(minLength: AppSpacing.sm)
            valueText
                .multilineTextAlignment(.trailing)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            labels
            valueText
        }
    }
}

private struct PlaceFieldRowPreviewList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            PlaceFieldRow(term: "Bundesland", genericLabel: "Gliedstaat (1. Ebene)", value: "Bayern")
            PlaceFieldRow(term: "Landkreis", genericLabel: "Kreis", value: "Landkreis Würzburg")
            PlaceFieldRow(term: "Gemeinde", genericLabel: "Gemeinde", value: "Ochsenfurt")
            PlaceFieldRow(term: nil, genericLabel: "Insel", value: "La Palma")
        }
        .padding()
    }
}

#Preview("Default") {
    PlaceFieldRowPreviewList()
}

#Preview("AX5") {
    PlaceFieldRowPreviewList()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    PlaceFieldRowPreviewList()
        .preferredColorScheme(.dark)
}
