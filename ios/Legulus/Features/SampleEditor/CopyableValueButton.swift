import SwiftUI
import UIKit

/// Ein Wert mit Beschriftung, der sich per Tap in die Zwischenablage
/// kopieren lässt (Koordinate und Höhe in der Sample-Ansicht). Sieht
/// aus wie Text, ist aber ein echter Button. Nach dem Tap steht für
/// kurze Zeit „Kopiert“ an der Stelle der Beschriftung, damit das
/// Layout nicht springt; VoiceOver bekommt eine Ansage.
///
/// `clipboardText` ist der Text für die Zwischenablage und darf von
/// der Anzeige abweichen (siehe `ClipboardText`).
struct CopyableValueButton<Content: View>: View {
    let caption: String
    let clipboardText: String
    let accessibilityLabel: String
    let announcement: String
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false
    @State private var copyCount = 0
    @State private var resetTask: Task<Void, Never>?

    /// Mindestgröße des Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44
    /// So lange bleibt „Kopiert“ stehen.
    private let confirmationDuration: Duration = .milliseconds(1500)

    var body: some View {
        Button(action: copy) {
            VStack(alignment: alignment, spacing: AppSpacing.xxs) {
                captionLine
                content()
            }
            .frame(minWidth: minTapTarget, minHeight: minTapTarget,
                   alignment: Alignment(horizontal: alignment, vertical: .center))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copyCount)
        .animation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion), value: showsCopied)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Kopiert in die Zwischenablage")
        .accessibilityAddTraits(.isButton)
        .onDisappear {
            // Der abgebrochene Timer setzt den Hinweis nicht mehr zurück;
            // ohne das stünde nach der Rückkehr dauerhaft „Kopiert“ da.
            resetTask?.cancel()
            showsCopied = false
        }
    }

    /// Beide Beschriftungen liegen übereinander im Layout und werden nur
    /// ein- und ausgeblendet. So ändert der Tap die Breite des Buttons
    /// nicht und das umgebende `ViewThatFits` springt nicht um.
    private var captionLine: some View {
        ZStack(alignment: Alignment(horizontal: alignment, vertical: .center)) {
            Text(caption)
                .opacity(showsCopied ? 0 : 1)
            Label("Kopiert", systemImage: "checkmark")
                .opacity(showsCopied ? 1 : 0)
        }
        .font(AppFont.footnote)
        .foregroundStyle(.secondary)
    }

    private func copy() {
        UIPasteboard.general.string = clipboardText
        copyCount += 1
        showsCopied = true
        AccessibilityNotification.Announcement(announcement).post()
        // Ein früher gestarteter Timer darf den neuen Hinweis nicht
        // vorzeitig ausblenden.
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: confirmationDuration)
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

#Preview("Default") {
    CopyableValueButtonPreview()
}

#Preview("AX5") {
    CopyableValueButtonPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    CopyableValueButtonPreview()
        .preferredColorScheme(.dark)
}

private struct CopyableValueButtonPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            CopyableValueButton(
                caption: "MGRS",
                clipboardText: "32UNA6938014686",
                accessibilityLabel: "Koordinate 32U NA 69380 14686, MGRS",
                announcement: "Koordinate kopiert"
            ) {
                Text("32U NA 69380 14686")
                    .font(AppFont.body.monospacedDigit())
            }
            CopyableValueButton(
                caption: "Höhe",
                clipboardText: "276m",
                accessibilityLabel: "Höhe 276 Meter",
                announcement: "Höhe kopiert"
            ) {
                Text("276 m")
                    .font(AppFont.body.monospacedDigit())
            }
        }
        .padding()
    }
}
