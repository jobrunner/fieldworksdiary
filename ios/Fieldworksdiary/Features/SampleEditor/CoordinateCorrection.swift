import FieldworksGeo
import Foundation
import SwiftUI

/// Moves a saved sample to a new coordinate — the correction path of the
/// edit form („Auf Karte zeigen“, „Ortsdaten neu abfragen“).
///
/// A sample with a manual place asks first („Ortsangaben neu
/// übernehmen?“, `retakePlaceDialog`): `request` holds the coordinate and
/// says whether to ask; `apply(keepManualPlace:)` writes it. The write
/// goes through `LocalSampleStore.updateCoordinate` (`location_source =
/// user`), which clears the old point's derived values and queues the
/// update. Then the place is resolved:
///
/// - with an Ortus answer already at hand (the form asked Ortus to
///   convert the input), that answer is written — no second request;
/// - otherwise online; offline it stays `pending` and the backend
///   enriches it after the sync.
///
/// A first coordinate for a sample without locality (a new sample still
/// waiting for its fix, a retrospective one from a photo without
/// position) also runs the offline locality fusion, so an offline pick
/// doesn't leave the locality empty.
@MainActor
final class CoordinateCorrection {
    /// Coordinate waiting for the „Ortsangaben neu übernehmen?“ answer.
    struct Pending {
        var latitude: Double
        var longitude: Double
        /// Written with the coordinate (nil clears the old accuracy).
        var horizontalAccuracy: Double?
        /// Ortus answer for exactly this coordinate, if already fetched.
        var response: OrtusResponse?
    }

    /// Shown when the coordinate could not be written.
    static let saveFailedMessage = "Koordinate konnte nicht gespeichert werden."

    private(set) var pending: Pending?

    private let store: LocalSampleStore
    private let localitiesStore: LocalLocalityStore
    private let mutationsStore: PendingMutationsStore
    private let resolver: SampleLocationResolver?
    private let sync: SyncRunner

    init(
        store: LocalSampleStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        resolver: SampleLocationResolver?,
        sync: SyncRunner
    ) {
        self.store = store
        self.localitiesStore = localitiesStore
        self.mutationsStore = mutationsStore
        self.resolver = resolver
        self.sync = sync
    }

    /// Holds `pending` for sample `sampleID`. Returns true when the
    /// sample's place is manual and the user must be asked first;
    /// false means: call `apply(keepManualPlace: true)` right away.
    func request(sampleID: String, _ pending: Pending) -> Bool {
        self.pending = pending
        let sample = try? store.fetchById(sampleID)
        return sample?.locationStatus == .manual
    }

    /// „Abbrechen“ / dialog dismissed: nothing is written.
    func cancel() {
        pending = nil
    }

    /// Writes the pending coordinate and starts the place resolution.
    /// `completion` runs once the place data was written (or given up).
    /// Returns false when nothing was pending or the write failed
    /// (logged; show `saveFailedMessage`).
    @discardableResult
    func apply(
        sampleID: String,
        keepManualPlace: Bool,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let pending else { return false }
        self.pending = nil
        let before = try? store.fetchById(sampleID)
        let needsLocality = before.map { sample in
            (sample.locality ?? "").isEmpty && !sample.hasCoordinate
        } ?? false
        do {
            try store.updateCoordinate(
                id: sampleID,
                latitude: pending.latitude,
                longitude: pending.longitude,
                horizontalAccuracy: pending.horizontalAccuracy,
                locationSource: .user,
                keepManualPlace: keepManualPlace,
                mutationsStore: mutationsStore
            )
        } catch {
            Log.persistence.error("coordinate correction failed: \(error.localizedDescription)")
            return false
        }
        if let response = pending.response {
            applyAnswer(response, sampleID: sampleID, needsLocality: needsLocality,
                        latitude: pending.latitude, longitude: pending.longitude)
            completion()
        } else if needsLocality {
            SampleCreation.completeLateFix(
                sampleID: sampleID,
                localitySource: .user,
                store: store,
                localitiesStore: localitiesStore,
                mutationsStore: mutationsStore,
                resolver: resolver,
                sync: sync,
                completion: completion
            )
        } else {
            resolveAfterCorrection(sampleID: sampleID, completion: completion)
        }
        return true
    }

    /// Coordinate precision of the stored WGS84 position (6 decimals).
    static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    // MARK: - private

    /// The Ortus answer that converted the input: fusion if needed, then
    /// the answer's place data, zone and DEM height.
    private func applyAnswer(
        _ response: OrtusResponse, sampleID: String, needsLocality: Bool,
        latitude: Double, longitude: Double
    ) {
        if needsLocality {
            do {
                try SampleCreation.attachFusedLocality(
                    sampleID: sampleID, latitude: latitude, longitude: longitude,
                    locationSource: .user, store: store, localitiesStore: localitiesStore,
                    mutationsStore: mutationsStore
                )
            } catch {
                Log.persistence.error("locality fusion after correction failed: \(error.localizedDescription)")
            }
        }
        if resolver?.apply(response, sampleID: sampleID) != true {
            Log.location.info("corrected sample \(sampleID, privacy: .public) stays pending until sync")
        }
        sync.kick()
    }

    /// Online resolution for a corrected coordinate. No offline
    /// inheritance here: the previous sample's place of the day says
    /// nothing about a moved point — it stays `pending` instead.
    private func resolveAfterCorrection(sampleID: String, completion: @escaping @MainActor () -> Void) {
        guard let resolver else {
            sync.kick()
            completion()
            return
        }
        let sync = self.sync
        Task { @MainActor in
            let resolved = await resolver.resolveOnline(sampleID: sampleID)
            if !resolved {
                Log.location.info("corrected sample \(sampleID, privacy: .public) stays pending until sync")
            }
            sync.kick()
            completion()
        }
    }
}

extension View {
    /// „Ortsangaben neu übernehmen?“ — asked before a corrected
    /// coordinate is written for a sample whose place was set by hand.
    /// `onAnswer(false)`: take the new point's place („Übernehmen“);
    /// `onAnswer(true)`: keep the manual place („Meine Angaben
    /// behalten“); `onCancel`: write nothing.
    func retakePlaceDialog(
        isPresented: Binding<Bool>,
        onAnswer: @escaping (_ keepManualPlace: Bool) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Ortsangaben neu übernehmen?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Übernehmen") { onAnswer(false) }
            Button("Meine Angaben behalten") { onAnswer(true) }
            Button("Abbrechen", role: .cancel, action: onCancel)
        } message: {
            Text(
                "Die Ortsangaben dieser Probe hast du von Hand gesetzt. Sollen für die neue Koordinate die ermittelten Ortsangaben übernommen werden?"
            )
        }
    }
}
