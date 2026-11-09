import FieldworksGeo
import Foundation

/// State of the place editor sheet for one sample (Phase O2).
///
/// Country first (`countries`, from `AdminLabelTable`), then only that
/// country's levels plus island / mountain range / mountain
/// (`fields`). Saving a changed place detaches only this sample onto a
/// `manual` placemark (`LocalSampleStore.setManualPlace`); a changed
/// height is stored with `elevation_source = manual`. Both go through
/// store methods that queue the outbox update — the editor never
/// writes a whole row copy.
@MainActor
final class PlaceEditorViewModel: ObservableObject, Identifiable {
    @Published private(set) var form: PlaceForm
    @Published var elevationText: String
    @Published private(set) var saveError: String?

    let sampleID: String
    /// All countries of the label table, sorted by German name.
    let countries: [(iso: String, name: String)]

    private let initialElevationText: String
    private let store: LocalSampleStore
    private let placemarks: LocalPlacemarkStore
    private let mutationsStore: PendingMutationsStore
    private let table: AdminLabelTable

    /// Nil when the sample doesn't exist (anymore).
    init?(
        sampleID: String,
        store: LocalSampleStore,
        placemarks: LocalPlacemarkStore,
        mutationsStore: PendingMutationsStore,
        table: AdminLabelTable = .shared
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

    /// Inline hint under the height field.
    var elevationError: String? {
        guard elevationChanged else { return nil }
        return parsedElevation == nil ? "Bitte eine Höhe in Metern eingeben, z. B. 312." : nil
    }

    var canSave: Bool {
        if elevationChanged, parsedElevation == nil { return false }
        return placeChanged || elevationChanged
    }

    /// Writes the changes. Returns true on success.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        saveError = nil
        do {
            if placeChanged, let place = form.place(table: table) {
                try store.setManualPlace(id: sampleID, place: place, placemarks: placemarks,
                                         mutationsStore: mutationsStore)
                Log.persistence.info("manual place saved for sample \(self.sampleID, privacy: .public)")
            }
            if elevationChanged, let elevation = parsedElevation {
                try store.setManualElevation(id: sampleID, elevation: elevation, mutationsStore: mutationsStore)
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
