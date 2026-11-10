import FieldworksGeo
import Foundation

/// State of the „Probe nachtragen“ dialog (Weg „Mit Koordinate“).
///
/// „Anlegen“ asks Ortus first; only a successful answer with a WGS84
/// position creates the sample. Any failure (no connection, HTTP
/// error, answer without `wgs84`, unparsable input) leaves the dialog
/// open with `errorMessage` and the inputs untouched; cancelling
/// creates nothing.
///
/// Opened from a photo whose Ortus query failed, the dialog starts
/// with the photo's position and the error; the photo and its capture
/// time go to the sample created from the dialog.
@MainActor
final class RetrospectiveCoordinateViewModel: ObservableObject {
    /// Photo waiting for the sample (fallback of „Aus Foto“).
    struct PendingPhoto {
        var data: Data
        var capture: PhotoCaptureTime?
    }

    @Published var code: String
    @Published var system: InputCoordinateSystem
    @Published var first: String
    @Published var second: String
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false

    private let suggestedCode: String
    private let suggestedRunning: Int?
    private let ortus: OrtusQuerying?
    private let creator: RetrospectiveSampleCreator
    private let photo: PendingPhoto?
    /// Set by a successful `submit()`: id and running number for the
    /// editor (`SampleEditorView(sampleID:isNew:suggestedRunning:)`).
    private(set) var created: InstantSampleCreator.Created?

    /// - Parameters:
    ///   - displayFormat: `AppConfig.coordinateDisplayFormat`; MGRS
    ///     preselects MGRS, every other format WGS 84.
    ///   - prefill: a position to start with (photo fallback).
    ///   - initialError: message shown on open (photo fallback).
    init(
        ortus: OrtusQuerying?,
        creator: RetrospectiveSampleCreator,
        displayFormat: CoordinateDisplayFormat,
        prefill: CoordinateInput? = nil,
        initialError: String? = nil,
        photo: PendingPhoto? = nil
    ) {
        self.ortus = ortus
        self.creator = creator
        self.photo = photo
        // The Ortus zone isn't known yet, so a photo's capture day is
        // read in the device zone here. Near midnight that day can differ
        // from the collecting day the sample gets once Ortus answers (its
        // begin is then read in the Ortus zone); the id stays as suggested.
        let begin = photo?.capture?.instant(in: creator.deviceZone()) ?? creator.now()
        let suggestion = creator.suggestion(begin: begin, zone: creator.deviceZone())
        suggestedCode = suggestion.id
        suggestedRunning = suggestion.running
        code = suggestion.id
        system = prefill?.system ?? Self.defaultSystem(for: displayFormat)
        first = prefill?.first ?? ""
        second = prefill?.second ?? ""
        errorMessage = initialError
    }

    static func defaultSystem(for format: CoordinateDisplayFormat) -> InputCoordinateSystem {
        format == .mgrs ? .mgrs : .wgs84
    }

    /// „Anlegen“. Returns the new sample's local id, or nil when nothing
    /// was created (`errorMessage` says why; a cancelled task stays
    /// silent).
    func submit() async -> String? {
        guard !isSubmitting else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil

        let input = CoordinateInput(system: system, first: first, second: second)
        // Unparsable fields are caught locally, before (and without) a request.
        do {
            _ = try input.queryItems()
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
        guard let ortus else {
            errorMessage = OrtusQueryError.offline.userMessage
            return nil
        }
        let response: OrtusResponse
        do {
            response = try await ortus.query(input: input)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return nil }
            errorMessage = Self.message(for: error)
            return nil
        }
        // Dialog cancelled while Ortus answered: nothing may appear.
        if Task.isCancelled { return nil }
        guard response.wgs84 != nil else {
            errorMessage = OrtusQueryError.noWGS84.userMessage
            return nil
        }

        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = typed == suggestedCode ? suggestedRunning : nil
        do {
            let result = try creator.create(
                response: response,
                code: .given(typed, running: running),
                capture: photo?.capture,
                photo: photo?.data
            )
            created = result
            return result.id
        } catch {
            Log.persistence.error("retrospective create failed: \(error.localizedDescription)")
            errorMessage = "Die Probe konnte nicht gespeichert werden."
            return nil
        }
    }

    // MARK: - private

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let ortusError as OrtusQueryError:
            ortusError.userMessage
        case is CoordinateInputError:
            "Bitte eine gültige Koordinate eingeben."
        default:
            OrtusQueryError.server(message: nil).userMessage
        }
    }
}
