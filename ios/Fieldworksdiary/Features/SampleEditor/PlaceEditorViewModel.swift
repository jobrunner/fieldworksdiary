import FieldworksGeo
import Foundation

/// State of the place editor sheet for one sample (Phase O2).
///
/// Country first (`countries`, from `AdminLabelTable`), then only that
/// country's levels plus island / mountain range / mountain
/// (`fields`). Saving a changed place detaches only this sample onto a
/// `manual` placemark (`LocalSampleStore.setManualPlace`); a changed
/// height is stored with `elevation_source = manual` and the optional
/// error ("Fehler (m)") typed next to it (empty = no accuracy). Both go through
/// store methods that queue the outbox update — the editor never
/// writes a whole row copy.
///
/// The edit form (`SampleFormView`) embeds the same state: the place
/// fields as its „Ortsdaten“ group, height and error in „Koordinate“
/// (there the error starts with the stored vertical accuracy).
@MainActor
final class PlaceEditorViewModel: ObservableObject, Identifiable {
    @Published private(set) var form: PlaceForm
    @Published var elevationText: String
    /// Optional error of the typed height in metres (starts empty in
    /// the sheet: the accuracy of an earlier height says nothing about a
    /// new one; the form starts with the stored value).
    @Published var accuracyText: String
    @Published private(set) var saveError: String?

    let sampleID: String
    /// All countries of the label table, sorted by German name.
    let countries: [(iso: String, name: String)]

    private let initialElevationText: String
    private let initialAccuracyText: String
    private let store: LocalSampleStore
    private let placemarks: LocalPlacemarkStore
    private let mutationsStore: PendingMutationsStore
    private let table: AdminLabelTable

    /// Nil when the sample doesn't exist (anymore).
    /// - Parameter prefillAccuracy: start the error field with the
    ///   stored vertical accuracy (edit form); the sheet starts empty.
    init?(
        sampleID: String,
        store: LocalSampleStore,
        placemarks: LocalPlacemarkStore,
        mutationsStore: PendingMutationsStore,
        table: AdminLabelTable = .shared,
        prefillAccuracy: Bool = false
    ) {
        guard let sample = try? store.fetchById(sampleID) else { return nil }
        self.sampleID = sampleID
        self.store = store
        self.placemarks = placemarks
        self.mutationsStore = mutationsStore
        self.table = table
        let current = sample.placemark.flatMap { try? placemarks.fetchById($0) }
        form = PlaceForm(place: current?.place)
        let text = sample.elevation.map(Self.format) ?? ""
        elevationText = text
        initialElevationText = text
        let accuracy = prefillAccuracy ? (sample.verticalAccuracy.map(Self.format) ?? "") : ""
        accuracyText = accuracy
        initialAccuracyText = accuracy
        countries = table.countries
            .map { (iso: $0.iso, name: PlaceDisplay.countryName($0.iso, table: table)) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var fields: [PlaceForm.Field] {
        form.fields(table: table)
    }

    func selectCountry(_ iso: String) {
        form.selectCountry(iso, table: table)
    }

    func value(for fieldID: String) -> String {
        form.values[fieldID] ?? ""
    }

    func setValue(_ value: String, for fieldID: String) {
        form.values[fieldID] = value
    }

    var placeChanged: Bool {
        form.isChanged(table: table)
    }

    var elevationChanged: Bool {
        elevationText.trimmingCharacters(in: .whitespacesAndNewlines) != initialElevationText
    }

    /// Typed height in metres; nil when empty or not a number.
    var parsedElevation: Double? {
        let raw = elevationText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !raw.isEmpty, let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    /// Typed error in metres; nil when empty or invalid.
    var parsedAccuracy: Double? {
        let raw = accuracyText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !raw.isEmpty, let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var accuracyTyped: Bool {
        !accuracyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The error differs from its start value (empty in the sheet).
    private var accuracyChanged: Bool {
        accuracyText.trimmingCharacters(in: .whitespacesAndNewlines) != initialAccuracyText
    }

    var accuracyError: String? {
        guard accuracyTyped, parsedAccuracy == nil else { return nil }
        return "Bitte einen Fehler in Metern eingeben, z. B. 5."
    }

    /// The height is written when it or the error was changed.
    private var elevationEdited: Bool {
        elevationChanged || accuracyChanged
    }

    /// Something was typed that isn't saved yet.
    var hasEdits: Bool {
        placeChanged || elevationEdited
    }

    /// Inline hint under the height field.
    var elevationError: String? {
        guard elevationEdited else { return nil }
        return parsedElevation == nil ? "Bitte eine Höhe in Metern eingeben, z. B. 312." : nil
    }

    var canSave: Bool {
        if elevationEdited, parsedElevation == nil { return false }
        if accuracyError != nil { return false }
        return placeChanged || elevationEdited
    }

    /// Writes the changes. Returns true on success.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        return write(elevation: elevationEdited)
    }

    /// Writes what is valid — the place when changed, the height and
    /// error when typed correctly — and leaves invalid input alone. The
    /// edit form saves this way when it is left. Returns false when
    /// nothing was written.
    @discardableResult
    func saveValidEdits() -> Bool {
        let elevationValid = elevationEdited && parsedElevation != nil && accuracyError == nil
        guard placeChanged || elevationValid else { return false }
        return write(elevation: elevationValid)
    }

    private func write(elevation writeElevation: Bool) -> Bool {
        saveError = nil
        do {
            if placeChanged, let place = form.place(table: table) {
                try store.setManualPlace(id: sampleID, place: place, placemarks: placemarks,
                                         mutationsStore: mutationsStore)
                Log.persistence.info("manual place saved for sample \(self.sampleID, privacy: .public)")
            }
            if writeElevation, let elevation = parsedElevation {
                try store.setManualElevation(id: sampleID, elevation: elevation,
                                             verticalAccuracy: parsedAccuracy, mutationsStore: mutationsStore)
                Log.persistence.info("manual elevation saved for sample \(self.sampleID, privacy: .public)")
            }
            return true
        } catch {
            Log.persistence.error("place edit save failed: \(error.localizedDescription)")
            saveError = "Ortsangaben konnten nicht gespeichert werden."
            return false
        }
    }

    private static func format(_ elevation: Double) -> String {
        elevation.rounded() == elevation
            ? String(format: "%.0f", elevation)
            : String(format: "%.1f", elevation).replacingOccurrences(of: ".", with: ",")
    }
}
