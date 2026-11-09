import Foundation

/// Pulls the place data that server samples reference but the device
/// doesn't have yet (Phase O2):
///
/// 1. Placemarks referenced via `placemark` / `placemark_suggestion`
///    that have no local row → fetched in batches and upserted (the
///    upsert merges onto locally created rows via `backend_id`).
/// 2. Features of samples with `location_status == backend_service`
///    that have none locally (e.g. a sample saved offline and enriched
///    by the backend) → fetched in batches and stored under the local
///    sample id.
///
/// Runs after `LocalSampleStore.upsert` (hydration) and after a
/// successful enrichment poll. Failures are logged and swallowed —
/// the next hydration retries.
@MainActor
struct SampleLocationHydration {
    let samples: LocalSampleStore
    let placemarks: LocalPlacemarkStore
    let features: LocalSampleFeatureStore
    let placemarkClient: PlacemarkSyncClient
    let featuresClient: SampleFeaturesSyncClient

    /// Ids per list request; keeps the filter URL short.
    static let placemarkBatch = 40
    static let featureBatch = 20

    func hydrate(_ remote: [Sample]) async {
        await hydratePlacemarks(remote)
        await hydrateFeatures(remote)
    }

    private func hydratePlacemarks(_ remote: [Sample]) async {
        let referenced = remote.flatMap { [$0.placemark, $0.placemarkSuggestion] }.compactMap { $0 }
        let missing: [String]
        do {
            missing = try placemarks.missingBackendIDs(referenced)
        } catch {
            Log.persistence.error("placemark lookup failed: \(error.localizedDescription)")
            return
        }
        for batch in missing.chunked(into: Self.placemarkBatch) {
            do {
                let fetched = try await placemarkClient.fetchMany(ids: batch)
                try placemarks.upsert(fetched)
                Log.sync.info("hydrated \(fetched.count, privacy: .public) placemarks")
            } catch {
                Log.sync.warning("placemark hydrate failed: \(error.localizedDescription)")
            }
        }
    }

    private func hydrateFeatures(_ remote: [Sample]) async {
        // backend sample id → local sample id, only for samples whose
        // features are missing locally.
        var wanted: [String: String] = [:]
        for r in remote where r.locationStatus == .backendService {
            guard let local = try? samples.fetchByBackendID(r.id),
                  (try? features.count(sampleID: local.id)) == 0
            else { continue }
            wanted[r.id] = local.id
        }
        if wanted.isEmpty { return }

        for batch in Array(wanted.keys).sorted().chunked(into: Self.featureBatch) {
            do {
                let fetched = try await featuresClient.fetchFeatures(sampleBackendIDs: batch)
                let grouped = Dictionary(grouping: fetched, by: \.sample)
                for (backendID, items) in grouped {
                    guard let localID = wanted[backendID] else { continue }
                    // Re-check: the on-device resolver may have stored
                    // its own set while the request was in flight.
                    guard (try? features.count(sampleID: localID)) == 0 else { continue }
                    try features.replace(sampleID: localID, features: items.map(\.ortusFeature))
                }
                Log.sync.info("hydrated \(fetched.count, privacy: .public) sample features")
            } catch {
                Log.sync.warning("feature hydrate failed: \(error.localizedDescription)")
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
