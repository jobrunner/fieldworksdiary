import AVFoundation
import SwiftUI
import UIKit

/// The live picture of a capture session, filling its frame. Reports
/// taps as device points (for focus) and pinches as magnification.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (CGPoint) -> Void
    var onPinchChanged: (CGFloat) -> Void
    var onPinchEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched)))
        // The picture itself says nothing to VoiceOver; the controls
        // around it carry the labels.
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview

        init(_ parent: CameraPreview) {
            self.parent = parent
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = view.previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: view))
            parent.onTap(point)
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                parent.onPinchChanged(recognizer.scale)
            case .ended, .cancelled, .failed:
                parent.onPinchEnded()
            default:
                break
            }
        }
    }
}
