import AVFoundation
import CoreLocation
import ImageIO

/// The capture session behind `CameraView`: rear camera, still photos as
/// JPEG files, one after the other without closing.
///
/// The photo is handed out as the bytes of
/// `AVCapturePhoto.fileDataRepresentation()` — the file as the camera
/// wrote it, with all EXIF data. Nothing here decodes, resizes or
/// re-encodes it. The camera does not know where it is; the position of
/// the shot comes from `locationProvider` and travels in the capture
/// settings (see `PhotoGPSMetadata`).
///
/// The AVFoundation objects live in `CameraCore` and are used on its
/// queue only; the published state changes on the main actor.
@MainActor
final class CameraSession: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        /// The user denied or cannot grant camera access.
        case unauthorized
        /// No camera (Simulator).
        case unavailable
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isCapturing = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto

    /// Called on the main actor with the file data of each photo.
    var onPhoto: ((Data) -> Void)?
    /// Called on the main actor when a capture failed.
    var onCaptureError: ((String) -> Void)?
    /// The position for the GPS block of the next shot; nil leaves the
    /// block out. Never waited for.
    var locationProvider: (() -> CLLocation?)?

    /// The capture session, for the preview layer.
    var session: AVCaptureSession {
        core.session
    }

    private let core = CameraCore()

    /// Upper bound of the pinch zoom; beyond it the picture is digital
    /// mush on every device.
    nonisolated static let maxZoom: CGFloat = 10

    /// Device types in order of preference. The virtual multi-camera
    /// devices come first: only they switch lenses by themselves when
    /// zooming or focusing close (macro).
    nonisolated static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
    ]

    nonisolated static func clampedZoom(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard value.isFinite else { return minimum }
        return Swift.min(Swift.max(value, minimum), Swift.min(maximum, maxZoom))
    }

    /// Settings for one shot: JPEG, the flash mode only when the device
    /// supports it, and the GPS block when a position is known.
    nonisolated static func photoSettings(
        flash: AVCaptureDevice.FlashMode,
        supportedFlash: [AVCaptureDevice.FlashMode],
        location: CLLocation?
    ) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = supportedFlash.contains(flash) ? flash : .off
        if let location {
            settings.metadata = [kCGImagePropertyGPSDictionary as String: PhotoGPSMetadata.dictionary(for: location)]
        }
        return settings
    }

    /// Factor of one tap on the zoom buttons.
    nonisolated static let zoomStep: CGFloat = 1.5

    /// The zoom factor the camera opens with. On the virtual devices
    /// that start with the ultra-wide lens, factor 1 is that lens; the
    /// first switch-over factor is the main lens.
    nonisolated static func initialZoom(deviceType: AVCaptureDevice.DeviceType, switchOverFactors: [CGFloat]) -> CGFloat {
        guard [.builtInTripleCamera, .builtInDualWideCamera].contains(deviceType),
              let main = switchOverFactors.first
        else { return 1 }
        return main
    }

    nonisolated static func flashLabel(_ mode: AVCaptureDevice.FlashMode) -> String {
        mode == .off ? "Blitz: aus" : "Blitz: automatisch"
    }

    // MARK: - lifecycle

    /// Asks for camera access if needed, configures the session once and
    /// starts it.
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .unauthorized
                return
            }
        default:
            state = .unauthorized
            return
        }
        let core = core
        state = await withCheckedContinuation { continuation in
            core.queue.async {
                continuation.resume(returning: core.configureAndRun())
            }
        }
    }

    func stop() {
        let core = core
        core.queue.async { core.stop() }
        if state == .running { state = .idle }
    }

    // MARK: - capture

    /// Takes one photo. Ignored while the previous one is still being
    /// captured, and never waits for a position.
    func capture() {
        guard state == .running, !isCapturing else { return }
        isCapturing = true
        let core = core
        let flash = flashMode
        let location = locationProvider?()
        core.queue.async { [weak self] in
            guard let self else { return }
            core.capture(flash: flash, location: location, delegate: self)
        }
    }

    func toggleFlash() {
        flashMode = flashMode == .off ? .auto : .off
    }

    // MARK: - focus and zoom

    /// Focus and expose at a point of the preview in device coordinates
    /// (0…1, as `AVCaptureVideoPreviewLayer.captureDevicePointConverted`
    /// returns them).
    func focus(at devicePoint: CGPoint) {
        let core = core
        core.queue.async { core.focus(at: devicePoint) }
    }

    /// Pinch: `factor` is the gesture's magnification since it began.
    func zoom(by factor: CGFloat) {
        let core = core
        core.queue.async { core.zoom(by: factor) }
    }

    func zoomEnded() {
        let core = core
        core.queue.async { core.zoomEnded() }
    }

    /// One step in or out — the button path next to the pinch, which
    /// VoiceOver and Switch Control cannot perform.
    func zoomIn() {
        stepZoom(Self.zoomStep)
    }

    func zoomOut() {
        stepZoom(1 / Self.zoomStep)
    }

    private func stepZoom(_ factor: CGFloat) {
        let core = core
        core.queue.async {
            core.zoom(by: factor)
            core.zoomEnded()
        }
    }

    /// Focus and expose for the centre of the picture — the button path
    /// next to tap-to-focus.
    func focusCenter() {
        focus(at: CGPoint(x: 0.5, y: 0.5))
    }
}

/// The AVFoundation objects of `CameraSession`. Everything except
/// `session` (handed to the preview layer) and `queue` is touched on
/// `queue` only, which is what makes the unchecked `Sendable` hold.
private final class CameraCore: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "app.legulus.camera.session")

    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Zoom factor when the current pinch began.
    private var zoomAtGestureStart: CGFloat = 1

    func configureAndRun() -> CameraSession.State {
        if device == nil {
            guard let camera = AVCaptureDevice.DiscoverySession(
                deviceTypes: CameraSession.preferredDeviceTypes, mediaType: .video, position: .back
            ).devices.first else { return .unavailable }
            guard let input = try? AVCaptureDeviceInput(device: camera) else {
                return .failed("Die Kamera lässt sich nicht öffnen.")
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return .failed("Die Kamera lässt sich nicht einrichten.")
            }
            session.addInput(input)
            session.addOutput(output)
            // Standard photo resolution of the device; the 48-MP mode
            // (maxPhotoDimensions) stays off on purpose.
            output.maxPhotoQualityPrioritization = .balanced
            session.commitConfiguration()
            device = camera
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            let initial = CameraSession.initialZoom(
                deviceType: camera.deviceType,
                switchOverFactors: camera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            )
            if initial != camera.videoZoomFactor, (try? camera.lockForConfiguration()) != nil {
                camera.videoZoomFactor = CameraSession.clampedZoom(
                    initial, min: camera.minAvailableVideoZoomFactor, max: camera.maxAvailableVideoZoomFactor
                )
                camera.unlockForConfiguration()
            }
            zoomAtGestureStart = camera.videoZoomFactor
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? .running : .failed("Die Kamera startet nicht.")
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func capture(flash: AVCaptureDevice.FlashMode, location: CLLocation?, delegate: AVCapturePhotoCaptureDelegate) {
        let settings = CameraSession.photoSettings(
            flash: flash, supportedFlash: output.supportedFlashModes, location: location
        )
        settings.photoQualityPrioritization = .balanced
        // Portrait and landscape end up in the file as held.
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle)
        {
            connection.videoRotationAngle = angle
        }
        output.capturePhoto(with: settings, delegate: delegate)
    }

    func focus(at devicePoint: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
    }

    func zoom(by factor: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = CameraSession.clampedZoom(
            zoomAtGestureStart * factor,
            min: device.minAvailableVideoZoomFactor,
            max: device.maxAvailableVideoZoomFactor
        )
        device.unlockForConfiguration()
    }

    func zoomEnded() {
        zoomAtGestureStart = device?.videoZoomFactor ?? 1
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isCapturing = false
            if let data {
                self.onPhoto?(data)
            } else {
                Log.ui.error("camera capture failed: \(message ?? "no data", privacy: .public)")
                self.onCaptureError?("Das Foto konnte nicht aufgenommen werden.")
            }
        }
    }
}
