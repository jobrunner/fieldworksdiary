import CoreLocation
import FieldworksGeo
import Foundation

/// State of the edit form („Bearbeiten“) of one saved sample (Phase N):
/// groups „Koordinate“, „Zeit“, „Ortsdaten“.
///
/// Saving follows the sample editor (Phase E): there is no „Fertig“
/// button; the custom back button calls `finishEditing()`, going to the
/// background calls `saveEdits()`.
///
/// - **Koordinate**: the fields start with the stored position as WGS 84
///   decimal (6 decimals), or as MGRS (5 digits) when that is the display
///   format. Switching the system clears them (no local reprojection). A typed position is taken over only through
///   „Ortsdaten neu abfragen“ (`queryOrtus()`: Ortus converts the input,
///   its WGS 84 answer is stored and its place data, zone and height
///   written without a second request) or through the map
///   (`mapPicked`). Both run the shared `CoordinateCorrection` path,
///   including the „Ortsangaben neu übernehmen?“ question. A failed
///   query leaves the stored coordinate and the input as they are.
///   Height and vertical error live in the embedded
///   `PlaceEditorViewModel` (a changed height is `manual`); the
///   horizontal error is written on save.
/// - **Zeit**: `SampleTimeWindow` rules; written through
///   `LocalSampleStore.saveEdits` (a retrospective sample's collecting
///   day follows its begin).
/// - **Ortsdaten**: the embedded `PlaceEditorViewModel` (manual place).
///
/// Leaving with a typed, not taken-over position (or an invalid height
/// or error) asks „Koordinate verwerfen?“; time and place changes are
/// saved in any case.
@MainActor
final class SampleFormViewModel: ObservableObject {
    // MARK: Koordinate

    /// Input system; changing it clears the fields.
    @Published var system: InputCoordinateSystem = .wgs84 {
        didSet {
            guard system != oldValue else { return }
            first = ""
            second = ""
            coordinateError = nil
        }
    }

    @Published var first = ""
    @Published var second = ""
    /// Horizontal error in metres (empty = none).
    @Published var horizontalAccuracyText = ""
    /// Inline error of the coordinate group (input, Ortus, write).
    @Published private(set) var coordinateError: String?
    @Published private(set) var isQuerying = false
    /// The stored position (WGS 84).
    @Published private(set) var storedCoordinate: CLLocationCoordinate2D?
    /// „Ortsangaben neu übernehmen?“ for a sample with a manual place.
    @Published var askRetakePlace = false
    /// Discard question raised by `finishEditing()`; `discardReason`
    /// says which one.
    @Published var askDiscardCoordinate = false
    @Published private(set) var discardReason: DiscardReason = .coordinate

    enum DiscardReason: Equatable {
        /// „Koordinate verwerfen?“: a typed position wasn't taken over.
        case coordinate
        /// „Ungültige Eingaben verwerfen?“: height or error can't be saved.
        case invalidValues
    }

    // MARK: Zeit

    /// nil only when the sample doesn't exist (anymore).
    @Published private(set) var time: SampleTimeWindow?

    // MARK: Ortsdaten (+ height of the coordinate group)

    /// Place fields, height and vertical error; replaced by a fresh one
    /// after new place data landed (unless the user typed something).
    @Published private(set) var place: PlaceEditorViewModel?
    @Published private(set) var saveError: String?

    let sampleID: String
    /// Set once the form was left through `finishEditing()`; later
    /// disappear hooks don't save again.
    private(set) var finished = false

    /// Input equal to the stored position; anything else is "not taken over".
    private var appliedInput = CoordinateInput(system: .wgs84)
    private var initialHorizontalAccuracyText = ""
    /// Time window the user started from (or last saved).
    private var baseTime: SampleTimeWindow?
    /// Row values the place group was built from.
    private var placeSource: PlaceSource?

    private let store: LocalSampleStore
    private let placemarkStore: LocalPlacemarkStore
    private let mutationsStore: PendingMutationsStore
    private let sync: SyncRunner
    private let ortus: OrtusQuerying?
    /// `AppConfig.coordinateDisplayFormat`: MGRS prefills MGRS.
    private let displayFormat: CoordinateDisplayFormat
    private let correction: CoordinateCorrection
    /// Device position CoreLocation already holds (no prompt, no
    /// updates); where the map starts for a sample without coordinate.
    private let lastKnownLocation: () -> CLLocationCoordinate2D?
    private var rowObservation: Task<Void, Never>?
    /// „Ortsdaten neu abfragen“ in flight. Owned here, not by the view:
    /// a Form section disappears while scrolling, the query must not.
    private var queryTask: Task<Void, Never>?

    private struct PlaceSource: Equatable {
        var placemark: String?
        var elevation: Double?
        var verticalAccuracy: Double?

        init(_ sample: LocalSample) {
            placemark = sample.placemark
            elevation = sample.elevation
            verticalAccuracy = sample.verticalAccuracy
        }
    }

    init(
        sampleID: String,
        store: LocalSampleStore,
        localitiesStore: LocalLocalityStore,
        placemarkStore: LocalPlacemarkStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        ortus: OrtusQuerying?,
        resolver: SampleLocationResolver?,
        displayFormat: CoordinateDisplayFormat = .default,
        lastKnownLocation: @escaping () -> CLLocationCoordinate2D? = { LocationProvider.lastKnownCoordinate() }
    ) {
        self.sampleID = sampleID
        self.lastKnownLocation = lastKnownLocation
        self.displayFormat = displayFormat
        self.store = store
        self.placemarkStore = placemarkStore
        self.mutationsStore = mutationsStore
        self.sync = sync
        self.ortus = ortus
        correction = CoordinateCorrection(
            store: store, localitiesStore: localitiesStore, mutationsStore: mutationsStore,
            resolver: resolver, sync: sync
        )
        guard let sample = try? store.fetchById(sampleID) else { return }
        time = SampleTimeWindow(sample)
        baseTime = time
        adoptCoordinate(sample)
        adoptHorizontalAccuracy(sample)
        rebuildPlace(sample)
    }

    deinit {
        rowObservation?.cancel()
        queryTask?.cancel()
    }

    var sampleExists: Bool {
        time != nil
    }

    // MARK: - Koordinate

    private var currentInput: CoordinateInput {
        CoordinateInput(system: system, first: first, second: second)
    }

    /// What „Ortsdaten neu abfragen“ sends: the stored WGS 84 position
    /// while the fields still show it (an MGRS prefill would shift it by
    /// up to a metre), else the typed input.
    private var queryInput: CoordinateInput {
        guard Self.trimmed(currentInput) == Self.trimmed(appliedInput), let stored = storedCoordinate else {
            return currentInput
        }
        return CoordinateInput(
            system: .wgs84, first: Self.format(stored.latitude), second: Self.format(stored.longitude)
        )
    }

    /// A typed position that wasn't taken over (empty fields don't count).
    var hasUnappliedCoordinate: Bool {
        let input = Self.trimmed(currentInput)
        guard input != Self.trimmed(appliedInput) else { return false }
        return !(input.first.isEmpty && input.second.isEmpty)
    }

    /// Height, vertical or horizontal error that can't be saved as typed.
    var hasInvalidCoordinateValues: Bool {
        if horizontalAccuracyError != nil { return true }
        guard let place else { return false }
        return place.elevationError != nil || place.accuracyError != nil
    }

    /// Typed horizontal error; nil when empty or invalid.
    var parsedHorizontalAccuracy: Double? {
        Self.parsePositive(horizontalAccuracyText)
    }

    var horizontalAccuracyError: String? {
        let raw = horizontalAccuracyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, parsedHorizontalAccuracy == nil else { return nil }
        return "Bitte einen Fehler in Metern eingeben, z. B. 5."
    }

    private var horizontalAccuracyChanged: Bool {
        horizontalAccuracyText.trimmingCharacters(in: .whitespacesAndNewlines) != initialHorizontalAccuracyText
    }

    /// Where the map starts and what the button says.
    enum MapStart: Equatable {
        /// „Auf Karte zeigen“: the point is preselected.
        case coordinate(CLLocationCoordinate2D)
        /// „Auf Karte wählen“ at the device's last known position.
        case lastKnown(CLLocationCoordinate2D)
        /// „Auf Karte wählen“ at the map's default region.
        case defaultRegion

        static func == (lhs: MapStart, rhs: MapStart) -> Bool {
            switch (lhs, rhs) {
            case let (.coordinate(a), .coordinate(b)), let (.lastKnown(a), .lastKnown(b)):
                a.latitude == b.latitude && a.longitude == b.longitude
            case (.defaultRegion, .defaultRegion):
                true
            default:
                false
            }
        }
    }

    /// The map button is always there: with a position (typed WGS 84 or
    /// stored) it shows it, without one the user picks a point, starting
    /// at the last known device position or the default region.
    var mapStart: MapStart {
        if let mapCenter { return .coordinate(mapCenter) }
        if let last = lastKnownLocation() { return .lastKnown(last) }
        return .defaultRegion
    }

    /// A typed WGS 84 position, else the stored one; nil without either.
    var mapCenter: CLLocationCoordinate2D? {
        if system == .wgs84,
           let lat = CoordinateConverter.parseGeographicComponent(first, isLatitude: true),
           let lon = CoordinateConverter.parseGeographicComponent(second, isLatitude: false)
        {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return storedCoordinate
    }

    /// „Ortsdaten neu abfragen“ from the view: runs `queryOrtus()` in a
    /// task this model owns, so it outlives the section's disappear
    /// while scrolling. One at a time; cancelled only when the form is
    /// left (`finishEditing`, „Verwerfen“, deinit).
    @discardableResult
    func startQuery() -> Task<Void, Never>? {
        guard queryTask == nil else { return queryTask }
        let task = Task { [weak self] in
            await self?.queryOrtus()
            self?.queryTask = nil
        }
        queryTask = task
        return task
    }

    func cancelQuery() {
        queryTask?.cancel()
        queryTask = nil
    }

    /// „Ortsdaten neu abfragen“: Ortus converts the input; its WGS 84
    /// answer becomes the stored position, then its place data, zone and
    /// height are written (correction rules). Any failure stays inline,
    /// the input and the stored coordinate untouched; a cancelled query
    /// stays silent.
    func queryOrtus() async {
        guard !isQuerying, sampleExists, !Task.isCancelled else { return }
        coordinateError = nil
        let input = queryInput
        do {
            _ = try input.queryItems()
        } catch {
            coordinateError = OrtusQueryError.userMessage(for: error)
            return
        }
        guard let ortus else {
            coordinateError = OrtusQueryError.offline.userMessage
            return
        }
        isQuerying = true
        defer { isQuerying = false }
        let response: OrtusResponse
        do {
            response = try await ortus.query(input: input)
        } catch {
            if OrtusQueryError.isCancellation(error) || Task.isCancelled { return }
            coordinateError = OrtusQueryError.userMessage(for: error)
            return
        }
        if Task.isCancelled { return }
        guard let wgs84 = response.wgs84 else {
            coordinateError = OrtusQueryError.noWGS84.userMessage
            return
        }
        requestCorrection(
            latitude: CoordinateCorrection.round6(wgs84.lat),
            longitude: CoordinateCorrection.round6(wgs84.lon),
            response: response
        )
    }

    /// „Übernehmen“ on the map: the fields show the point in WGS 84 and
    /// it is taken over right away (place data resolved online, offline
    /// after the sync).
    func mapPicked(latitude: Double, longitude: Double) {
        guard sampleExists else { return }
        coordinateError = nil
        let lat = CoordinateCorrection.round6(latitude)
        let lon = CoordinateCorrection.round6(longitude)
        system = .wgs84
        first = Self.format(lat)
        second = Self.format(lon)
        requestCorrection(latitude: lat, longitude: lon, response: nil)
    }

    /// Answer of „Ortsangaben neu übernehmen?“.
    func applyCorrection(keepManualPlace: Bool) {
        askRetakePlace = false
        guard correction.pending != nil else { return }
        let applied = correction.apply(sampleID: sampleID, keepManualPlace: keepManualPlace) { [weak self] in
            self?.refreshFromRow()
        }
        guard applied else {
            coordinateError = CoordinateCorrection.saveFailedMessage
            return
        }
        if let row = try? store.fetchById(sampleID) {
            adoptCoordinate(row)
            if !horizontalAccuracyChanged || horizontalAccuracyError == nil { adoptHorizontalAccuracy(row) }
        }
        refreshFromRow()
        observeRow()
    }

    /// „Abbrechen“ in „Ortsangaben neu übernehmen?“: nothing is written,
    /// the input stays.
    func cancelCorrection() {
        askRetakePlace = false
        correction.cancel()
    }

    private func requestCorrection(latitude: Double, longitude: Double, response: OrtusResponse?) {
        // Typed time, place data and height go first: the correction
        // sees a place the user just set by hand (and asks about it), and
        // a new Ortus zone moves the saved (all-day) window, not a stale one.
        do {
            _ = try saveTime()
        } catch {
            Log.persistence.error("sample form time save failed: \(error.localizedDescription)")
            saveError = "Änderungen konnten nicht gespeichert werden."
        }
        savePlace()
        let pending = CoordinateCorrection.Pending(
            latitude: latitude,
            longitude: longitude,
            // A new point keeps an error only when the user typed one;
            // the old fix's accuracy says nothing about it.
            horizontalAccuracy: horizontalAccuracyChanged ? parsedHorizontalAccuracy : nil,
            response: response
        )
        if correction.request(sampleID: sampleID, pending) {
            askRetakePlace = true
        } else {
            applyCorrection(keepManualPlace: true)
        }
    }

    // MARK: - Zeit

    func setBeginDate(_ date: Date) {
        time?.setBegin(date)
    }

    func setEndDate(_ date: Date) {
        time?.setEnd(date)
    }

    func setTimezone(_ identifier: String) {
        time?.setTimezone(identifier)
    }

    func setAllDay(_ allDay: Bool) {
        time?.setAllDay(allDay)
    }

    // MARK: - leaving

    /// Custom back button. Saves time, place, height and error; with a
    /// typed position that wasn't taken over (or an invalid height or
    /// error) it asks „Koordinate verwerfen?“ first and returns false.
    func finishEditing() -> Bool {
        guard sampleExists else {
            finished = true
            return true
        }
        saveEdits()
        if hasUnappliedCoordinate || hasInvalidCoordinateValues {
            discardReason = hasUnappliedCoordinate ? .coordinate : .invalidValues
            askDiscardCoordinate = true
            return false
        }
        cancelQuery()
        finished = true
        return true
    }

    /// „Verwerfen“: the typed position (and invalid height or error) is
    /// dropped; everything else was saved already.
    func discardCoordinateAndFinish() {
        askDiscardCoordinate = false
        cancelQuery()
        resetCoordinateInput()
        finished = true
    }

    /// „Weiter bearbeiten“.
    func keepEditing() {
        askDiscardCoordinate = false
    }

    /// Saves every valid change without dialogs (background, disappear,
    /// and before the discard question). A typed position is never
    /// written here — only `queryOrtus()` and the map take it over.
    func saveEdits() {
        guard sampleExists else { return }
        saveError = nil
        var wrote = false
        do {
            wrote = try saveTime() || wrote
            wrote = try saveHorizontalAccuracy() || wrote
        } catch {
            Log.persistence.error("sample form save failed: \(error.localizedDescription)")
            saveError = "Änderungen konnten nicht gespeichert werden."
        }
        wrote = savePlace() || wrote
        if wrote { sync.kick() }
    }

    // MARK: - row

    /// Observes the row so place data, zone and height written in the
    /// background (resolver, sync) show up. Idempotent.
    func observeRow() {
        guard rowObservation == nil, sampleExists else { return }
        let rows = store.observeSample(id: sampleID)
        rowObservation = Task { [weak self] in
            for await row in rows {
                if Task.isCancelled { return }
                guard let self, let row else { return }
                self.adopt(row)
            }
        }
    }

    func refreshFromRow() {
        guard let row = try? store.fetchById(sampleID) else { return }
        adopt(row)
    }

    // MARK: - private

    /// Takes over a row written in the background without touching
    /// what the user is editing.
    private func adopt(_ row: LocalSample) {
        // Unedited time fields follow the row (an Ortus zone); edited
        // ones keep their base, so only the user's changes are written.
        if time == baseTime {
            time = SampleTimeWindow(row)
            baseTime = time
        }
        let previous = storedCoordinate
        let moved = previous?.latitude != row.latitude || previous?.longitude != row.longitude
        if moved, !hasUnappliedCoordinate { adoptCoordinate(row) }
        if moved {
            storedCoordinate = Self.coordinate(row)
        }
        if !horizontalAccuracyChanged { adoptHorizontalAccuracy(row) }
        if PlaceSource(row) != placeSource, place?.hasEdits != true {
            rebuildPlace(row)
        }
    }

    private func adoptCoordinate(_ sample: LocalSample) {
        storedCoordinate = Self.coordinate(sample)
        let input = storedCoordinate
            .map { prefill($0) } ?? CoordinateInput(system: RetrospectiveCoordinateViewModel.defaultSystem(for: displayFormat))
        appliedInput = input
        system = input.system
        first = input.first
        second = input.second
    }

    /// The stored position in the prefill system: MGRS (5 digits) for the
    /// MGRS display format, else WGS 84 decimal.
    private func prefill(_ c: CLLocationCoordinate2D) -> CoordinateInput {
        if RetrospectiveCoordinateViewModel.defaultSystem(for: displayFormat) == .mgrs,
           let mgrs = CoordinateConverter.toMGRS(lat: c.latitude, lon: c.longitude, precision: 5)
        {
            return CoordinateInput(system: .mgrs, first: mgrs)
        }
        return CoordinateInput(system: .wgs84, first: Self.format(c.latitude), second: Self.format(c.longitude))
    }

    private func adoptHorizontalAccuracy(_ sample: LocalSample) {
        let text = sample.horizontalAccuracy.map(Self.formatMetres) ?? ""
        horizontalAccuracyText = text
        initialHorizontalAccuracyText = text
    }

    private func resetCoordinateInput() {
        system = appliedInput.system
        first = appliedInput.first
        second = appliedInput.second
        horizontalAccuracyText = initialHorizontalAccuracyText
        coordinateError = nil
        if place?.hasEdits == true, let row = try? store.fetchById(sampleID) {
            // Drops an invalid height or error (a valid one was saved).
            rebuildPlace(row)
        }
    }

    private func rebuildPlace(_ sample: LocalSample) {
        place = PlaceEditorViewModel(
            sampleID: sample.id, store: store, placemarks: placemarkStore,
            mutationsStore: mutationsStore, prefillAccuracy: true
        )
        placeSource = PlaceSource(sample)
    }

    /// Writes the time fields that differ from `baseTime`.
    private func saveTime() throws -> Bool {
        guard let time, let baseTime, time != baseTime,
              var row = try store.fetchById(sampleID) else { return false }
        time.write(into: &row, base: baseTime)
        try store.saveEdits(row, mutationsStore: mutationsStore)
        Log.persistence.info("form time saved for sample \(self.sampleID, privacy: .public)")
        if let fresh = try store.fetchById(sampleID) {
            self.time = SampleTimeWindow(fresh)
            self.baseTime = self.time
        }
        return true
    }

    private func saveHorizontalAccuracy() throws -> Bool {
        guard horizontalAccuracyChanged, horizontalAccuracyError == nil else { return false }
        try store.setHorizontalAccuracy(
            id: sampleID, horizontalAccuracy: parsedHorizontalAccuracy, mutationsStore: mutationsStore
        )
        initialHorizontalAccuracyText = horizontalAccuracyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Saves typed place data, height and vertical error as far as
    /// valid; an invalid height or error stays in its field.
    @discardableResult
    private func savePlace() -> Bool {
        guard let place, place.hasEdits else { return false }
        let invalid = place.elevationError != nil || place.accuracyError != nil
        guard place.saveValidEdits() else {
            if let error = place.saveError { saveError = error }
            return false
        }
        if let row = try? store.fetchById(sampleID) {
            let elevationText = place.elevationText
            let accuracyText = place.accuracyText
            rebuildPlace(row)
            if invalid {
                self.place?.elevationText = elevationText
                self.place?.accuracyText = accuracyText
            }
        }
        return true
    }

    private static func coordinate(_ sample: LocalSample) -> CLLocationCoordinate2D? {
        guard let lat = sample.latitude, let lon = sample.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func trimmed(_ input: CoordinateInput) -> CoordinateInput {
        CoordinateInput(
            system: input.system,
            first: input.first.trimmingCharacters(in: .whitespacesAndNewlines),
            second: input.second.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// WGS 84 decimal with 6 decimals, "." as separator.
    static func format(_ degrees: Double) -> String {
        String(format: "%.6f", degrees)
    }

    private static func formatMetres(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func parsePositive(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !raw.isEmpty, let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return value
    }
}
