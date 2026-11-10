import FieldworksGeo
import Foundation
import UIKit

/// Capture time of a picked photo. Without an explicit offset the
/// reading is a wall clock in an unknown zone: it was read in
/// `readIn` and is re-read in the sample's zone once that is known.
struct PhotoCaptureTime: Equatable {
    var date: Date
    /// Zone the wall clock was read in; nil when the photo carried
    /// `OffsetTimeOriginal` (the instant is exact).
    var readIn: TimeZone?

    init?(_ metadata: PhotoMetadata, fallbackZone: TimeZone) {
        guard let date = metadata.capturedAt else { return nil }
        self.date = date
        readIn = metadata.hadExplicitOffset ? nil : fallbackZone
    }

    /// The capture instant for a sample in `zone`.
    func instant(in zone: TimeZone) -> Date {
        guard let readIn else { return date }
        return PhotoMetadataReader.reinterpret(date, from: readIn, to: zone)
    }
}

/// Creates samples entered afterwards („Probe nachtragen“), shared by
/// the coordinate dialog and the photo import: inserts the row via
/// `LocalSampleStore.createRetrospective`, writes an Ortus answer that
/// is already at hand (no second request), attaches a picked photo and
/// kicks the sync. Never registers with `PendingFixService`.
@MainActor
struct RetrospectiveSampleCreator {
    let store: LocalSampleStore
    let photoStore: LocalPhotoStore
    let mutationsStore: PendingMutationsStore
    /// nil skips writing the place data (tests that don't care).
    let resolver: SampleLocationResolver?
    let sync: SyncRunner
    let deviceZone: () -> TimeZone
    let now: () -> Date

    /// Id the sample gets: typed in the dialog, or the suggestion for
    /// its collecting day.
    enum Code {
        /// Typed or kept in the dialog. `running` is the suggestion's
        /// running number when the user kept it unchanged.
        case given(String, running: Int?)
        /// Suggestion for the sample's begin, read in its zone.
        case suggested
    }

    /// Ortus converted the coordinate: the sample gets the answer's
    /// WGS84 position (6 decimals), the Ortus zone (device zone when
    /// the answer has none), begin = capture time or now, and the place
    /// data of the answer.
    func create(
        response: OrtusResponse,
        code: Code,
        capture: PhotoCaptureTime?,
        photo: Data?
    ) throws -> InstantSampleCreator.Created {
        guard let wgs84 = response.wgs84 else { throw OrtusQueryError.noWGS84 }
        let lat = Self.round6(wgs84.lat)
        let lon = Self.round6(wgs84.lon)
        let ortusZone = OrtusMapper.map(response, lat: lat, lon: lon).geo.timezone
            .flatMap { TimeZone(identifier: $0) }
        let zone = ortusZone ?? deviceZone()
        let begin = capture?.instant(in: zone) ?? now()
        let (id, running) = resolve(code, begin: begin, zone: zone)
        let sample = try store.createRetrospective(
            code: id,
            latitude: lat,
            longitude: lon,
            beginDate: begin,
            timezone: zone.identifier,
            timezoneSource: ortusZone == nil ? .device : .locationService,
            mutationsStore: mutationsStore
        )
        resolver?.apply(response, sampleID: sample.id)
        finish(sample, photo: photo)
        return InstantSampleCreator.Created(id: sample.id, suggestedRunning: running)
    }

    /// Photo without position: sample without coordinate, begin =
    /// capture time or now, device zone. The user completes it in the
    /// form.
    func createWithoutPosition(
        code: Code,
        capture: PhotoCaptureTime?,
        photo: Data?
    ) throws -> InstantSampleCreator.Created {
        let zone = deviceZone()
        let begin = capture?.instant(in: zone) ?? now()
        let (id, running) = resolve(code, begin: begin, zone: zone)
        let sample = try store.createRetrospective(
            code: id,
            latitude: nil,
            longitude: nil,
            beginDate: begin,
            timezone: zone.identifier,
            timezoneSource: .device,
            mutationsStore: mutationsStore
        )
        finish(sample, photo: photo)
        return InstantSampleCreator.Created(id: sample.id, suggestedRunning: running)
    }

    /// Suggested id for a sample beginning at `begin` in `zone`, from
    /// the same Phase Z window `createRetrospective` will store.
    func suggestion(begin: Date, zone: TimeZone) -> (id: String, running: Int?) {
        let windowBegin = SampleTime.defaultWindow(createdAt: begin, in: zone).begin
        return store.peekSuggestion(for: windowBegin, in: zone)
    }

    // MARK: - private

    private func resolve(_ code: Code, begin: Date, zone: TimeZone) -> (String, Int?) {
        switch code {
        case let .given(id, running):
            (id, running)
        case .suggested:
            suggestion(begin: begin, zone: zone)
        }
    }

    private func finish(_ sample: LocalSample, photo: Data?) {
        if let photo { attachPhoto(photo, to: sample.id) }
        sync.kick()
        Log.persistence.info(
            "retrospective sample \(sample.id, privacy: .public) created, coordinate: \(sample.hasCoordinate, privacy: .public), photo: \(photo != nil, privacy: .public)"
        )
    }

    /// Normal photo path (`PhotoStorage.write`, `LocalPhotoStore.insert`),
    /// best effort: the sample already exists, a failed photo is logged.
    private func attachPhoto(_ data: Data, to sampleID: String) {
        guard let image = UIImage(data: data) else {
            Log.persistence.error("retrospective photo not decodable for sample \(sampleID, privacy: .public)")
            return
        }
        let photoID = UUID().uuidString
        do {
            let path = try PhotoStorage.write(image: image, sampleID: sampleID, photoID: photoID)
            let timestamp = Date()
            try photoStore.insert(LocalPhoto(
                id: photoID,
                sampleId: sampleID,
                localPath: path,
                backendId: nil,
                syncStatus: .pending,
                syncError: nil,
                clientUuid: photoID,
                clientUpdatedAt: timestamp,
                createdAt: timestamp
            ))
        } catch {
            Log.persistence.error("retrospective photo persist failed: \(error.localizedDescription)")
        }
    }

    private static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}
