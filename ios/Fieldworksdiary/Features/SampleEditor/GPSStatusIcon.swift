import CoreLocation
import SwiftUI

/// Small status icon for the editor's location section. The icon
/// pulses while the location is being acquired, then settles into
/// a solid filled icon once a fix arrives. The denied/failed paths
/// surface a slashed icon in the same physical slot so the user can
/// see "GPS is off" at a glance.
///
/// A11y: the surrounding label is the announcement — this icon stays
/// `.accessibilityHidden(true)` so VoiceOver doesn't read decorative
/// status twice.
struct GPSStatusIcon: View {
    let status: LocationProvider.Status

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbolName)
            .font(.title2)
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: isLoading && !reduceMotion)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch status {
        case .idle, .requestingAuthorization, .locating:
            return "location.viewfinder"
        case .fixed:
            return "location.fill"
        case .denied:
            return "location.slash"
        case .failed:
            return "location.slash"
        }
    }

    private var color: Color {
        switch status {
        case .fixed: return AppColor.brandPrimaryText
        case .denied, .failed: return .red
        case .idle, .requestingAuthorization, .locating: return .secondary
        }
    }

    private var isLoading: Bool {
        switch status {
        case .idle, .requestingAuthorization, .locating: return true
        case .fixed, .denied, .failed: return false
        }
    }
}
