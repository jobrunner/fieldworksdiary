import SwiftUI

extension LocalSample {
    /// The server appended a conflict suffix to the ID the user sent
    /// (`originalCode` is set and differs from `sampleID`). Cleared
    /// when the user edits the ID.
    var hasIdConflict: Bool {
        guard let originalCode, !originalCode.isEmpty else { return false }
        return originalCode != sampleID
    }
}

/// Hint „ID doppelt vergeben – bitte prüfen“ for a sample whose ID got
/// a conflict suffix. Icon plus text, so it does not rely on colour.
/// Use it wherever a sample ID is shown (list rows, detail, editor).
struct IdConflictHint: View {
    static let text = "ID doppelt vergeben – bitte prüfen"

    var body: some View {
        Label {
            Text(Self.text)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.warning)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Default") {
    IdConflictHint().padding()
}

#Preview("AX5") {
    IdConflictHint().padding().dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    IdConflictHint().padding().preferredColorScheme(.dark)
}
