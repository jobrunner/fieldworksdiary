import SwiftUI
import UIKit

extension View {
    /// Disables the navigation controller's interactive pop gestures —
    /// the edge swipe and, on iOS 26, the full-width content swipe —
    /// while this view is on screen, and restores their previous state
    /// when it leaves.
    ///
    /// Why: the sample editor must be left through its own back button
    /// (`SampleEditorViewModel.finishEditing()`), which validates the
    /// id. `navigationBarBackButtonHidden(true)` is not a reliable way
    /// to turn the swipe off on iOS 26, and a swipe-back would skip the
    /// empty-id dialog of a new sample (`onDisappear` only saves
    /// silently). The editor keeps `onDisappear` as the last-resort
    /// save for every other way out (pop-to-root, a gesture this guard
    /// doesn't know about).
    func interactivePopDisabled() -> some View {
        background(InteractivePopGuard().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Invisible child controller that reaches the hosting navigation
/// controller once it is in the hierarchy.
private struct InteractivePopGuard: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> GuardController {
        GuardController()
    }

    func updateUIViewController(_: GuardController, context _: Context) {}

    final class GuardController: UIViewController {
        /// Gesture states before we disabled them; nil while not active.
        private var saved: [(UIGestureRecognizer, Bool)]?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            disable()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // The navigation controller may only be reachable now.
            disable()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        private var popGestures: [UIGestureRecognizer] {
            guard let nav = navigationController else { return [] }
            var gestures: [UIGestureRecognizer] = []
            if let edge = nav.interactivePopGestureRecognizer { gestures.append(edge) }
            if #available(iOS 26.0, *), let content = nav.interactiveContentPopGestureRecognizer {
                gestures.append(content)
            }
            return gestures
        }

        private func disable() {
            guard saved == nil else { return }
            let gestures = popGestures
            guard !gestures.isEmpty else { return }
            saved = gestures.map { ($0, $0.isEnabled) }
            for gesture in gestures {
                gesture.isEnabled = false
            }
        }

        private func restore() {
            guard let saved else { return }
            for (gesture, wasEnabled) in saved {
                gesture.isEnabled = wasEnabled
            }
            self.saved = nil
        }
    }
}
