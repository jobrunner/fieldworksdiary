import Combine
import FieldworksGeo
import Foundation

/// Aggregates the data the home dashboard renders: the active
/// collector + fieldtrip + recent sample summary plus counts for the
/// menu rows.
///
/// Doesn't drive a live `ValueObservation` — refresh is cheap (small
/// SELECTs / counts) and the view kicks it on `.task` and when the
/// add-sample sheet dismisses, which covers every state change the
/// user can trigger.
@MainActor
final class HomeViewModel: ObservableObject {
    struct ActiveFieldtrip: Equatable {
        let id: String
        let title: String
        let localityName: String?
    }

    struct RecentSample: Equatable {
        let id: String
        let code: String
        let locality: String?
    }

    @Published var collectorName: String = ""
    @Published var activeFieldtrip: ActiveFieldtrip?
    @Published var recentSample: RecentSample?
    @Published var sampleCount: Int = 0
    @Published var markedCount: Int = 0
    @Published var fieldtripCount: Int = 0
    @Published var localityCount: Int = 0
    @Published var photoCount: Int = 0

    private let auth: AuthSession
    private let samples: LocalSampleStore
    private let fieldtrips: LocalFieldtripStore
    private let localities: LocalLocalityStore
    private let photos: LocalPhotoStore
    private let placemarks: LocalPlacemarkStore?

    /// The rollover hour comes from the user's settings (read fresh);
    /// "today" is the day in the device zone.
    private let timeZone: TimeZone = .current

    init(
        auth: AuthSession,
        samples: LocalSampleStore,
        fieldtrips: LocalFieldtripStore,
        localities: LocalLocalityStore,
        photos: LocalPhotoStore,
        placemarks: LocalPlacemarkStore? = nil
    ) {
        self.auth = auth
        self.samples = samples
        self.fieldtrips = fieldtrips
        self.localities = localities
        self.photos = photos
        self.placemarks = placemarks
    }

    func refresh() {
        collectorName = displayName(for: auth.currentUser)
        sampleCount = (try? samples.count()) ?? 0
        markedCount = (try? samples.countMarked()) ?? 0
        fieldtripCount = (try? fieldtrips.count()) ?? 0
        localityCount = (try? localities.count()) ?? 0
        photoCount = (try? photos.count()) ?? 0

        activeFieldtrip = loadActiveFieldtrip()
        recentSample = loadRecentSample()
    }

    // MARK: - private

    private func displayName(for user: AuthUser?) -> String {
        guard let user else { return "" }
        if !user.displayName.isEmpty { return user.displayName }
        if !user.abbreviation.isEmpty { return user.abbreviation }
        return user.email
    }

    private func loadActiveFieldtrip() -> ActiveFieldtrip? {
        let key = SampleTime.collectingDay(
            Date(), cutoffHour: SampleIDSettings.current().cutoffHour, in: timeZone
        )
        guard let ft = try? fieldtrips.fetchByCollectingDay(key) else { return nil }
        let title = ft.title.isEmpty
            ? "Sammeltag \(formattedShort(ft.collectingDay))"
            : ft.title
        let localityName = localityName(for: ft.locality)
        return ActiveFieldtrip(id: ft.id, title: title, localityName: localityName)
    }

    private func loadRecentSample() -> RecentSample? {
        guard let sample = try? samples.mostRecent() else { return nil }
        return RecentSample(
            id: sample.id,
            code: sample.backendCode ?? sample.sampleID,
            locality: placeName(for: sample)
        )
    }

    /// Municipality (or next higher filled level) of the sample's place.
    private func placeName(for sample: LocalSample) -> String? {
        guard let placemarks, let id = sample.placemark, !id.isEmpty else { return nil }
        return PlaceDisplay.shortName((try? placemarks.fetchById(id))?.place)
    }

    private func localityName(for id: String?) -> String? {
        guard let id, !id.isEmpty,
              let loc = try? localities.fetchById(id) else { return nil }
        return loc.name.isEmpty ? nil : loc.name
    }

    /// "2026-05-20" → "20.05.2026". Falls back to the raw key if it
    /// doesn't parse — defensive against schema drift.
    private func formattedShort(_ key: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = timeZone
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "de_DE")
        out.timeZone = timeZone
        out.dateFormat = "dd.MM.yyyy"
        return out.string(from: date)
    }
}
