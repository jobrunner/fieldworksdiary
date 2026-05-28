@testable import Fieldworksdiary
import XCTest

/// Tests aus Spec §5.5 (client-side). The trivial algorithm has
/// no branches worth mining — these four cases cover everything
/// future Android / Web implementations also need to match.
final class LocalityFusionTests: XCTestCase {
    private func cand(_ id: String, _ lat: Double, _ lon: Double) -> LocalityFusion.Candidate {
        LocalityFusion.Candidate(id: id, latitude: lat, longitude: lon)
    }

    /// Spec example: Sample at (X, Y), locality at (X+30m, Y) → attach.
    func testCloseCandidate_Attaches() {
        // 30 m east of the sample at 49.79° N (~ 0.000418° lon).
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: [cand("nearby", 49.79, 9.940418)]
        )
        XCTAssertEqual(result?.id, "nearby")
    }

    /// Spec example: Sample at (X, Y), locality at (X+200m, Y) → no match.
    func testFarCandidate_NoMatch() {
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: [cand("far", 49.79, 9.9428)] // ~200 m east
        )
        XCTAssertNil(result)
    }

    func testEmptyCandidates_NoMatch() {
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: []
        )
        XCTAssertNil(result)
    }

    /// Boundary check: a candidate just inside the 50 m horizon
    /// attaches (the spec says `<=`, not `<`). We use ~49 m east
    /// instead of an exact-50 m fixture so floating-point drift on
    /// the haversine doesn't make the test flaky.
    func testBoundaryAtRadius_Attaches() {
        // ~49 m east of the sample (1 m ≈ 0.0000139° lon at 49.79° N).
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: [cand("edge", 49.79, 9.940680)]
        )
        XCTAssertEqual(result?.id, "edge")
    }

    /// When two candidates qualify, the nearest one wins. This isn't
    /// Spec §5.5 directly but it's the obvious behavioural
    /// expectation — and it differs from the server's
    /// FlagAmbiguous branch, which is the whole point of the
    /// asymmetric split.
    func testTwoCandidates_NearestWins() {
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: [
                cand("far", 49.79, 9.94042), // ~30 m east
                cand("near", 49.79, 9.94014) // ~10 m east
            ]
        )
        XCTAssertEqual(result?.id, "near")
    }

    /// `excludingID` keeps the algorithm useful for the
    /// re-fuse-after-edit case. Without it, the sample's own
    /// locality would always win at 0 m.
    func testExcludingID_SkipsSelf() {
        let result = LocalityFusion.offlineFuseLocality(
            sampleLatitude: 49.79, sampleLongitude: 9.94,
            candidates: [
                cand("self", 49.79, 9.94), // 0 m — but excluded
                cand("other", 49.79, 9.940418) // ~30 m east
            ],
            excludingID: "self"
        )
        XCTAssertEqual(result?.id, "other")
    }
}
