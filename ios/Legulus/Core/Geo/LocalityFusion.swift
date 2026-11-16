import Foundation

/// Trivial offline locality fusion (Spec §5.1 / R6.3).
///
/// The asymmetric design says: clients implement only the bone-
/// dead-simplest algorithm so parallel implementations on Android
/// and Web cannot drift. The server (R6.1) does the heavy lifting
/// — adaptive radius, ambiguity handling, centroid updates — and
/// corrects after-the-fact via the LocalityRemap event stream.
///
/// What this client does:
///
///     function offlineFuseLocality(sample, localLocalities) -> Locality?:
///         R = 50  // metres
///         candidates = localLocalities
///             where haversine(sample.coord, loc.coord) <= R
///             sorted by distance ascending
///         return candidates.first  // empty → nil → caller creates new
///
/// That is it. No ambiguity branch, no accuracy-aware radius, no
/// centroid recalculation. Spec §5.1, verbatim.
enum LocalityFusion {
    /// Default radius. Spec hard-codes 50 m; callers can tighten or
    /// loosen via the `radius` parameter.
    static let defaultRadiusM = 50.0

    /// A slim view of a locality this algorithm needs. Mirrors the
    /// pure-Go `fusion.Candidate` shape on the backend.
    struct Candidate: Equatable {
        let id: String
        let latitude: Double
        let longitude: Double
    }

    /// Returns the closest locality inside `radius` metres of the
    /// sample's coordinate, or `nil` if no candidate qualifies. The
    /// caller is expected to create a fresh `LocalLocality` when the
    /// result is `nil`.
    ///
    /// Self-exclude: if the sample is already attached to a locality
    /// in `candidates` (matched by id via the optional
    /// `excludingID`), that candidate is skipped — useful for the
    /// re-fuse-after-edit case where the sample's own locality
    /// would otherwise win the distance contest at 0 m.
    static func offlineFuseLocality(
        sampleLatitude: Double,
        sampleLongitude: Double,
        candidates: [Candidate],
        radius: Double = defaultRadiusM,
        excludingID: String? = nil
    ) -> Candidate? {
        var best: Candidate?
        var bestDistance = Double.infinity
        for c in candidates {
            if let excludingID, c.id == excludingID { continue }
            let d = haversineMeters(
                sampleLatitude, sampleLongitude,
                c.latitude, c.longitude
            )
            if d <= radius, d < bestDistance {
                best = c
                bestDistance = d
            }
        }
        return best
    }
}

// MARK: - Haversine

/// Great-circle distance between two (lat, lon) points in metres.
/// Mean Earth radius 6 371 000 m — sub-percent error at any latitude
/// we care about. Kept file-private so the Geo namespace doesn't
/// pile up; the grouping Go side has its own copy.
private func haversineMeters(
    _ lat1: Double, _ lon1: Double,
    _ lat2: Double, _ lon2: Double
) -> Double {
    let earthRadius = 6_371_000.0
    let phi1 = lat1 * .pi / 180
    let phi2 = lat2 * .pi / 180
    let dPhi = (lat2 - lat1) * .pi / 180
    let dLambda = (lon2 - lon1) * .pi / 180

    let a = sin(dPhi / 2) * sin(dPhi / 2) +
        cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return earthRadius * c
}
