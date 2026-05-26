import Foundation

/// Pulls Spec §5.3 LocalityRemap events from the backend and
/// applies them locally. Runs alongside the other hydrators
/// (samples/fieldtrips/localities) — the polling cursor lives in
/// `UserDefaults` keyed by the authenticated user id so a
/// device-switch + relogin starts fresh.
///
/// `Notification.Name.localityRemapApplied` fires after each apply,
/// carrying the event as `object`, so the UI can surface a toast
/// ("3 Samples wurden in 'Am Wasser' übernommen.") without having
/// to subscribe to this puller directly.
@MainActor
final class RemapEventsPuller: ObservableObject {
    let localitiesStore: LocalLocalityStore
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?
    /// Returns the authenticated user id, or "" if none. Used to
    /// scope the cursor key.
    let userIDProvider: () -> String

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    init(
        localitiesStore: LocalLocalityStore,
        endpointProvider: @escaping () -> String,
        authProvider: @escaping () -> AuthSession? = { nil },
        userIDProvider: @escaping () -> String = { "" }
    ) {
        self.localitiesStore = localitiesStore
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.userIDProvider = userIDProvider
    }

    /// Pull every event since the persisted cursor and apply each
    /// one. Single-flight: an overlapping call short-circuits.
    func pull() async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let client = RemapEventClient(endpoint: endpoint, auth: authProvider())
            let events = try await client.listSince(currentCursor())
            for event in events {
                applyOne(event)
                // Advance the cursor *per event* so a mid-batch
                // crash doesn't replay the whole stream.
                setCursor(event.created)
            }
            lastError = nil
        } catch let err as SampleClientError {
            lastError = err.errorDescription
            Log.sync.error("remap pull failed: \(err.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            Log.sync.error("remap pull failed: \(error.localizedDescription)")
        }
    }

    /// Reset the cursor — used by AppContainer on user-switch.
    func resetCursor() {
        UserDefaults.standard.removeObject(forKey: cursorKey)
    }

    // MARK: - private

    private func applyOne(_ event: LocalityRemapEvent) {
        do {
            let moved = try localitiesStore.applyRemap(
                oldID: event.oldLocalityID,
                newID: event.newLocalityID
            )
            Log.sync.info("remap applied: \(moved, privacy: .public) samples → \(event.newLocalityID, privacy: .public)")
            NotificationCenter.default.post(
                name: .localityRemapApplied,
                object: event,
                userInfo: ["movedCount": moved]
            )
        } catch {
            Log.sync.error("remap apply failed: \(error.localizedDescription)")
        }
    }

    private var cursorKey: String {
        let uid = userIDProvider()
        return "fwd.remap.cursor." + (uid.isEmpty ? "default" : uid)
    }

    private func currentCursor() -> Date? {
        guard let raw = UserDefaults.standard.string(forKey: cursorKey),
              let date = parseISO(raw) else { return nil }
        return date
    }

    private func setCursor(_ date: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        UserDefaults.standard.set(formatter.string(from: date), forKey: cursorKey)
    }

    private func parseISO(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

extension Notification.Name {
    /// Posted after a single `LocalityRemapEvent` was applied to
    /// the local store. The `object` is the event itself; the
    /// `userInfo["movedCount"]` carries the number of samples that
    /// were actually re-pointed.
    static let localityRemapApplied = Notification.Name("fwd.localityRemapApplied")
}
