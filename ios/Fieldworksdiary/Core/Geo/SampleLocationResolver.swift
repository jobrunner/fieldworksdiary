import FieldworksGeo
import Foundation

/// Fills a freshly saved sample's place data on the device (Phase O2).
///
/// Flow in the editor: the sample is saved first (never blocked by
/// this type), then `resolveOnline` asks Ortus; if that returns
/// `false` (offline, no endpoint, timeout, HTTP error), the caller
/// runs `inheritOffline`. The backend enriches the sample again after
/// sync unless its `location_status` is already `backend_service`.
///
/// Rules mirror the backend enricher (`internal/enrichment`):
/// - pending/inherited: a `backend_service` placemark is looked up or
///   created and set; status becomes `backend_service`.
/// - manual: the placemark stays; a differing Ortus place is offered
///   as `placemark_suggestion`.
/// - no place in the answer (open sea): geo + features only, no
///   placemark; status still becomes `backend_service` (deliberately
///   unlike the backend, which leaves it — the device already did the
///   query, a re-run would yield the same answer).
/// - Geo values and features are always replaced; the DEM height is
///   used only when the sample has no height of its own (no
///   `elevationSource`; 0 m with a source counts as a height).
/// - The Ortus time zone is adopted unless it was set manually.
///
/// When the sample is already on the server (`backendId` set), every
/// write queues a `.sample/.update` outbox row, so the place data
/// reaches the backend even if the create push went out before the
/// resolver finished.
@MainActor
final class SampleLocationResolver {
    private let ortus: OrtusQuerying?
    private let samples: LocalSampleStore
    private let placemarks: LocalPlacemarkStore
    private let features: LocalSampleFeatureStore
    private let mutations: PendingMutationsStore?
    private let labels: AdminLabelTable

    init(
        ortus: OrtusQuerying?,
        samples: LocalSampleStore,
        placemarks: LocalPlacemarkStore,
        features: LocalSampleFeatureStore,
        mutations: PendingMutationsStore? = nil,
        labels: AdminLabelTable = .shared
    ) {
        self.ortus = ortus
        self.samples = samples
        self.placemarks = placemarks
        self.features = features
        self.mutations = mutations
        self.labels = labels
    }

    /// Queries Ortus for the sample's coordinate and writes the result.
    /// Returns `true` when the sample was resolved (status
    /// `backend_service`, or a manual sample whose geo data was
    /// refreshed); `false` when nothing was written and the caller
    /// should fall back to `inheritOffline`.
    func resolveOnline(sampleID: String) async -> Bool {
        guard let ortus else { return false }
        guard let sample = try? samples.fetchById(sampleID),
              let lat = sample.latitude, let lon = sample.longitude
        else { return false }
        if sample.locationStatus == .backendService { return true }

        let response: OrtusResponse
        do {
            response = try await ortus.query(lat: lat, lon: lon)
        } catch {
            Log.network.warning(
                "ortus unavailable for sample \(sampleID, privacy: .public): \(error.localizedDescription)"
            )
            return false
        }

        let result = OrtusMapper.map(response, lat: lat, lon: lon, table: labels)
        do {
            return try apply(result, sampleID: sampleID, lat: lat, lon: lon)
        } catch {
            Log.persistence.error(
                "ortus result write failed for sample \(sampleID, privacy: .public): \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Offline fallback: copies the placemark of the most recent
    /// earlier sample of the same collecting day and marks the sample
    /// `inherited`. Without such a sample it stays `pending`.
    func inheritOffline(sampleID: String) throws {
        guard var sample = try samples.fetchById(sampleID) else { return }
        guard sample.locationStatus == .pending else { return }
        guard let placemarkID = try samples.latestPlacemarkID(
            collectingDay: sample.collectingDay,
            excluding: sampleID
        ) else {
            Log.location.info("no earlier place today for sample \(sampleID, privacy: .public), stays pending")
            return
        }
        sample.placemark = placemarkID
        sample.locationStatus = .inherited
        try samples.update(sample)
        enqueueUpdateIfPushed(sample, pushFeatures: false)
        Log.location.info("sample \(sampleID, privacy: .public) inherited place offline")
    }

    // MARK: - private

    /// Re-reads the sample (it may have changed while Ortus answered)
    /// and writes placemark, status, geo values, height and features.
    private func apply(_ result: OrtusResult, sampleID: String, lat: Double, lon: Double) throws -> Bool {
        guard var sample = try samples.fetchById(sampleID) else { return false }
        // A coordinate moved meanwhile (or a sync landed the server's
        // enrichment): this answer no longer applies.
        guard let curLat = sample.latitude, let curLon = sample.longitude,
              abs(curLat - lat) < Self.coordEpsilon, abs(curLon - lon) < Self.coordEpsilon
        else { return false }
        if sample.locationStatus == .backendService { return true }
        let hadSuggestion = sample.placemarkSuggestion != nil

        if let place = result.place {
            let candidate = try placemarks.lookupOrCreate(place: place, source: .backendService)
            switch sample.locationStatus {
            case .pending, .inherited:
                sample.placemark = candidate.id
                sample.placemarkSuggestion = nil
                sample.locationStatus = .backendService
            case .manual:
                let currentHash = try sample.placemark
                    .flatMap { try placemarks.fetchById($0) }?.place.dedupHash
                sample.placemarkSuggestion = place.dedupHash == currentHash ? nil : candidate.id
            case .backendService:
                break
            }
        } else if sample.locationStatus == .manual {
            sample.placemarkSuggestion = nil
        } else {
            sample.locationStatus = .backendService
        }

        Self.applyGeo(result.geo, to: &sample)
        Self.applyDEMHeight(result.geo, to: &sample)
        Self.applyTimezone(result.geo, to: &sample)
        try samples.update(sample)
        try features.replace(sampleID: sampleID, features: result.features)
        // A manual sample whose stale suggestion was dropped must clear
        // it on the server too (nil is never sent on its own).
        let clearsSuggestion = hadSuggestion && sample.placemarkSuggestion == nil
        enqueueUpdateIfPushed(sample, pushFeatures: true, clearsSuggestion: clearsSuggestion)

        Log.location.info(
            "sample \(sampleID, privacy: .public) resolved via ortus: status \(sample.locationStatus.rawValue, privacy: .public), \(result.features.count, privacy: .public) features"
        )
        return true
    }

    /// Queues the place data for the server when the create push has
    /// already landed; before that the pending create carries it.
    /// A failed enqueue is logged, not thrown: the local write already
    /// succeeded and must not be reported as a failed resolution.
    private func enqueueUpdateIfPushed(_ sample: LocalSample, pushFeatures: Bool, clearsSuggestion: Bool = false) {
        guard let mutations, let backendID = sample.backendId, !backendID.isEmpty else { return }
        do {
            _ = try mutations.enqueue(
                entityType: .sample,
                entityId: sample.id,
                op: .update,
                payload: SampleUpdatePayload(pushFeatures: pushFeatures, clearsSuggestion: clearsSuggestion).encoded
            )
        } catch {
            Log.persistence.error(
                "place update enqueue failed for sample \(sample.id, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    /// Same tolerance as the backend enricher's `coordEpsilon`.
    private static let coordEpsilon = 1e-7

    private static func applyGeo(_ g: SampleGeo, to s: inout LocalSample) {
        s.slopeDeg = g.slopeDeg
        s.aspectDeg = g.aspectDeg
        s.aspectCompass = nonEmpty(g.aspectCompass)
        s.terrainFlat = g.terrainFlat
        s.bearingLabel = nonEmpty(g.bearingLabel)
        s.bearingReference = nonEmpty(g.bearingReference)
        s.bearingCompass = nonEmpty(g.bearingCompass)
        s.bearingDistanceKm = g.bearingDistanceKm
        s.bearingInside = g.bearingInside
        s.mtbSheetNumber = nonEmpty(g.mtbSheetNumber)
        s.mtbSheetName = nonEmpty(g.mtbSheetName)
        s.mtbQuadrant = g.mtbQuadrant == 0 ? nil : g.mtbQuadrant
    }

    /// DEM height only when the sample has no height of its own (no
    /// source, or an earlier DEM value). GPS — including 0 m — and
    /// manual heights are never replaced.
    private static func applyDEMHeight(_ g: SampleGeo, to s: inout LocalSample) {
        guard let dem = g.elevationDEM else { return }
        switch s.elevationSource {
        case nil, .backendService:
            s.elevation = dem
            s.elevationSource = .backendService
            s.verticalAccuracy = g.elevationDEMAccuracy
        case .locationService, .manual:
            return
        }
    }

    /// Zone from Ortus (`timezones-2026a`) replaces a device or earlier
    /// location-service zone; a manual zone stays, and an empty or
    /// unknown id leaves the sample untouched. Never touches
    /// `collectingDay`, `fieldtrip` or `sampleID`: those were fixed when
    /// the sample was saved. The queued update already carries
    /// `timezone`/`timezone_source`.
    private static func applyTimezone(_ g: SampleGeo, to s: inout LocalSample) {
        guard s.timezoneSource != .manual,
              let tz = g.timezone, !tz.isEmpty,
              TimeZone(identifier: tz) != nil
        else { return }
        s.timezone = tz
        s.timezoneSource = .locationService
    }

    private static func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}
