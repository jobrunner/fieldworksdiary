import SwiftUI

/// Visual indicator for a row's sync state. Single source of truth
/// — was duplicated in `SamplesListView`, `MarkedSamplesView` and
/// the photo gallery; now one component renders the badge everywhere.
///
/// The badge is a compact icon + optional label combo. Pass
/// `compact: true` for list-row trailing slots; `compact: false`
/// renders the longer description (used in the sample editor's
/// success card).
struct SyncStatusBadge: View {
    let status: SyncStatus
    var compact: Bool = true

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            icon
            if !compact {
                Text(description)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .synced:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColor.syncSynced)
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(AppColor.syncPending)
        case .syncing:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.syncFailed)
        }
    }

    private var description: String {
        switch status {
        case .synced: return "Synchronisiert"
        case .pending: return "Wartet auf Sync"
        case .syncing: return "Synchronisiere …"
        case .failed: return "Sync fehlgeschlagen"
        }
    }
}

#Preview("Compact") {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
        SyncStatusBadge(status: .synced)
        SyncStatusBadge(status: .pending)
        SyncStatusBadge(status: .syncing)
        SyncStatusBadge(status: .failed)
    }
    .padding()
}

#Preview("Verbose") {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
        SyncStatusBadge(status: .synced, compact: false)
        SyncStatusBadge(status: .pending, compact: false)
        SyncStatusBadge(status: .syncing, compact: false)
        SyncStatusBadge(status: .failed, compact: false)
    }
    .padding()
}
