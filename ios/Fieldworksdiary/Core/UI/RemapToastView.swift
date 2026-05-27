import SwiftUI

/// A dezenter bottom toast that surfaces server-side locality merges
/// (Spec §5.3 / R6.2). When the `RemapEventsPuller` applies a remap it
/// posts `Notification.Name.localityRemapApplied`; this modifier
/// listens, resolves the target locality's name from the local store,
/// and shows "N Proben wurden in 'Am Wasser' übernommen." for a few
/// seconds.
///
/// Attach once near the app root: `HomeView().remapToast()`.
private struct RemapToastModifier: ViewModifier {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var message: String?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    toast(message)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(AppMotion.respecting(AppMotion.base, reduceMotion: reduceMotion), value: message)
            .onReceive(NotificationCenter.default.publisher(for: .localityRemapApplied)) { note in
                handle(note)
            }
    }

    private func toast(_ text: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(AppColor.brandPrimary)
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.subhead)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .appShadow(.elevated)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func handle(_ note: Notification) {
        let moved = (note.userInfo?["movedCount"] as? Int) ?? 0
        guard let event = note.object as? LocalityRemapEvent else { return }

        let resolvedName = (try? container.localitiesStore.fetchById(event.newLocalityID))?.name
        let target: String
        if let name = resolvedName, !name.isEmpty {
            target = "„\(name)“"
        } else {
            target = "einem anderen Fundort"
        }
        let probe = moved == 1 ? "Probe wurde" : "Proben wurden"
        message = "\(moved) \(probe) in \(target) übernommen."

        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            message = nil
        }
    }
}

extension View {
    /// Surface locality-merge toasts. Attach once near the app root.
    func remapToast() -> some View {
        modifier(RemapToastModifier())
    }
}
