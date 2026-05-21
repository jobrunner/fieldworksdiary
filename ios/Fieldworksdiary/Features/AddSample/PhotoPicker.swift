import PhotosUI
import SwiftUI
import UIKit

/// SwiftUI bridge around `UIImagePickerController` for camera capture.
/// We use the legacy controller (not `PhotosPicker`) because we want
/// the immediate camera-launch experience for the in-field workflow.
///
/// `onImage` is called with the captured `UIImage` (or nil if the user
/// cancelled). The caller dismisses the sheet either way — see
/// `AddSampleView` for the integration.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Camera if available (real device); else fall back to the
        // photo library so the Simulator workflow still produces a
        // photo and we can exercise the add-sample path end-to-end.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void

        init(onImage: @escaping (UIImage?) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            onImage(nil)
        }
    }
}
