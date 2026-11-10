import FieldworksGeo
import Foundation

/// „Probe nachtragen → Aus Foto“: turns the original data of one
/// picked photo into a sample.
///
/// - With GPS: Ortus is asked for the position (`.wgs84`). Success →
///   sample with the place data, begin = capture time (without offset
///   re-read in the Ortus zone), id suggested for the capture day.
///   Failure → `.needsDialog`: the coordinate dialog opens with the
///   photo's position and the error; the photo waits for that sample.
/// - Without GPS: sample right away, without coordinate, begin =
///   capture time or now, device zone.
///
/// The photo is attached in every case; no background fix is started.
@MainActor
struct RetrospectivePhotoImporter {
    /// Seed for the coordinate dialog when Ortus failed for the photo.
    struct DialogSeed: Identifiable {
        let id = UUID()
        let input: CoordinateInput
        let errorMessage: String
        let photo: RetrospectiveCoordinateViewModel.PendingPhoto
    }

    enum Outcome {
        case created(InstantSampleCreator.Created)
        case needsDialog(DialogSeed)
    }

    let ortus: OrtusQuerying?
    let creator: RetrospectiveSampleCreator

    /// Throws `CancellationError` when the task was cancelled, or a
    /// store error when the sample could not be written.
    func importPhoto(_ data: Data) async throws -> Outcome {
        let deviceZone = creator.deviceZone()
        let metadata = PhotoMetadataReader.read(data, fallbackZone: deviceZone)
        let capture = PhotoCaptureTime(metadata, fallbackZone: deviceZone)

        guard let position = metadata.coordinate else {
            Log.ui.info("photo import without position, capture time: \(capture != nil, privacy: .public)")
            return try .created(creator.createWithoutPosition(code: .suggested, capture: capture, photo: data))
        }

        let input = CoordinateInput(
            system: .wgs84,
            first: String(format: "%.6f", position.lat),
            second: String(format: "%.6f", position.lon)
        )
        let pending = RetrospectiveCoordinateViewModel.PendingPhoto(data: data, capture: capture)
        guard let ortus else {
            return .needsDialog(DialogSeed(
                input: input, errorMessage: OrtusQueryError.offline.userMessage, photo: pending
            ))
        }
        let response: OrtusResponse
        do {
            response = try await ortus.query(input: input)
        } catch {
            if OrtusQueryError.isCancellation(error) || Task.isCancelled {
                throw CancellationError()
            }
            let message = (error as? OrtusQueryError)?.userMessage
                ?? OrtusQueryError.server(message: nil).userMessage
            return .needsDialog(DialogSeed(input: input, errorMessage: message, photo: pending))
        }
        try Task.checkCancellation()
        guard response.wgs84 != nil else {
            return .needsDialog(DialogSeed(
                input: input, errorMessage: OrtusQueryError.noWGS84.userMessage, photo: pending
            ))
        }
        return try .created(creator.create(response: response, code: .suggested, capture: capture, photo: data))
    }
}
