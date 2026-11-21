import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

/// Full-screen camera for a series of voucher photos. It stays open
/// after every shot: shutter, a counter of this session, the last
/// picture, „Fertig“. There is no „use photo“ step.
///
/// `onPhoto` receives the camera's JPEG file for each shot and stores
/// it; when it throws (disk full, …) the camera shows the error and
/// does not count the shot, so no photo is lost silently.
struct CameraView: View {
    let onPhoto: (Data) throws -> Void
    let onDone: () -> Void

    @StateObject private var camera = CameraSession()
    /// Locates while the camera is open, for the GPS block of the
    /// photos. The shutter never waits for it.
    @StateObject private var location = LocationProvider()

    @State private var count = 0
    @State private var lastPhoto: UIImage?
    @State private var errorMessage: String?
    /// The last fix of this session; survives the provider going back
    /// to „locating“ for the next one.
    @State private var lastFix = FixBox()

    /// How often the position is refreshed while the camera is open;
    /// below `LocationThreshold.staleness`.
    private let fixRefreshInterval: Duration = .seconds(10)

    @ScaledMetric(relativeTo: .body) private var shutterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var lastPhotoSize: CGFloat = 56
    /// Width of the shutter's ring.
    private let ringWidth: CGFloat = 4
    /// Mindestgröße eines Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44
    /// Pixel size of the preview of the last photo.
    private let lastPhotoPixels: CGFloat = 240

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .task {
            camera.onPhoto = store
            camera.onCaptureError = { errorMessage = $0 }
            camera.locationProvider = { [lastFix] in
                // Only a fix that is still fresh: a series can last
                // minutes and metres. Without one the photo carries no
                // GPS rather than the place the series began at.
                guard let fix = lastFix.location, LocationThreshold.accepts(fix) else { return nil }
                return fix
            }
            location.requestFix()
            await camera.start()
            // The provider stops after each fix; keep asking while the
            // camera is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: fixRefreshInterval)
                if Task.isCancelled { break }
                location.requestFix()
            }
        }
        .onChange(of: location.status) { _, status in
            if case let .fixed(fix) = status { lastFix.location = fix }
        }
        .onDisappear { camera.stop() }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var content: some View {
        switch camera.state {
        case .idle, .running:
            VStack(spacing: 0) {
                topBar
                CameraPreview(
                    session: camera.session,
                    onTap: { camera.focus(at: $0) },
                    onPinchChanged: { camera.zoom(by: $0) },
                    onPinchEnded: { camera.zoomEnded() }
                )
                .overlay(alignment: .bottom) { errorBanner }
                bottomBar
            }
        case .unauthorized:
            notice(
                "Legulus darf die Kamera nicht benutzen.",
                detail: "Erlaube den Zugriff in den Einstellungen, um Belegfotos aufzunehmen.",
                settingsButton: true
            )
        case .unavailable:
            notice("Auf diesem Gerät gibt es keine Kamera.", detail: nil, settingsButton: false)
        case let .failed(message):
            notice(message, detail: nil, settingsButton: false)
        }
    }

    private var topBar: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                camera.toggleFlash()
            } label: {
                Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : "bolt.badge.automatic.fill")
                    .font(AppFont.sectionTitle)
                    .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(CameraSession.flashLabel(camera.flashMode))
            .accessibilityHint("Schaltet zwischen automatischem Blitz und ohne Blitz um.")
            // Zoom and focus by button as well: pinch and tap on the
            // picture are gestures VoiceOver and Switch Control cannot
            // perform.
            iconButton("minus.magnifyingglass", label: "Herauszoomen") { camera.zoomOut() }
            iconButton("plus.magnifyingglass", label: "Hineinzoomen") { camera.zoomIn() }
            iconButton("scope", label: "In der Bildmitte scharfstellen") { camera.focusCenter() }
            Spacer(minLength: AppSpacing.sm)
            doneButton
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppFont.sectionTitle)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var doneButton: some View {
        Button("Fertig", action: onDone)
            .font(AppFont.bodyEmphasized)
            .frame(minWidth: minTapTarget, minHeight: minTapTarget)
            .contentShape(Rectangle())
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            lastPhotoView
                .frame(maxWidth: .infinity, alignment: .leading)
            shutter
            Text(countText)
                .font(AppFont.body.monospacedDigit())
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                // The shutter carries the count as its value.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.lg)
    }

    private var shutter: some View {
        Button {
            camera.capture()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: ringWidth)
                Circle().fill(.white).padding(ringWidth + AppSpacing.xxs)
            }
            .frame(width: shutterSize, height: shutterSize)
            .opacity(camera.isCapturing ? 0.4 : 1)
            .contentShape(Circle())
        }
        .disabled(camera.state != .running || camera.isCapturing)
        .accessibilityLabel("Foto aufnehmen")
        .accessibilityValue(countText)
    }

    @ViewBuilder
    private var lastPhotoView: some View {
        if let lastPhoto {
            Image(uiImage: lastPhoto)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: lastPhotoSize, height: lastPhotoSize)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .accessibilityLabel("Zuletzt aufgenommenes Foto")
        } else {
            Color.clear
                .frame(width: lastPhotoSize, height: lastPhotoSize)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote)
                .foregroundStyle(.white)
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.danger, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(AppSpacing.lg)
        }
    }

    private func notice(_ title: String, detail: String?, settingsButton: Bool) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "camera.fill")
                .font(AppFont.screenTitle)
                .accessibilityHidden(true)
            Text(title)
                .font(AppFont.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(AppFont.body)
                    .multilineTextAlignment(.center)
            }
            if settingsButton {
                Button("Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            doneButton
        }
        .foregroundStyle(.white)
        .padding(AppSpacing.xl)
    }

    private var countText: String {
        count == 1 ? "1 Foto" : "\(count) Fotos"
    }

    /// Hands the photo to `onPhoto`; counts and shows it only when it
    /// was stored.
    private func store(_ data: Data) {
        do {
            try onPhoto(data)
        } catch {
            Log.ui.error("camera photo not stored: \(error.localizedDescription, privacy: .public)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Das Foto konnte nicht gespeichert werden."
            AccessibilityNotification.Announcement("Foto nicht gespeichert").post()
            return
        }
        errorMessage = nil
        count += 1
        lastPhoto = PhotoStorage.thumbnail(data: data, maxPixel: lastPhotoPixels)
        AccessibilityNotification.Announcement("Foto \(count) aufgenommen").post()
    }
}

/// Holds the latest fix for the capture closure, which outlives the
/// view value that created it.
private final class FixBox {
    var location: CLLocation?
}

#Preview("Ohne Kamera") {
    CameraView(onPhoto: { _ in }, onDone: {})
}

#Preview("AX5") {
    CameraView(onPhoto: { _ in }, onDone: {})
        .dynamicTypeSize(.accessibility5)
}
