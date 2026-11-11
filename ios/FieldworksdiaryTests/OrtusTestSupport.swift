@testable import Fieldworksdiary
import FieldworksGeo
import Foundation

/// Ortus answers for tests of the typed-coordinate paths (Phase N).
enum OrtusFixtures {
    static func decode(_ json: String) throws -> OrtusResponse {
        try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
    }

    /// Ochsenfurt place data (trimmed `shared/testdata/ortus/query_de_ochsenfurt.json`)
    /// with the given WGS84 position and time zone.
    static func answerJSON(lat: Double, lon: Double, zone: String = "Europe/Berlin") -> String {
        """
        {
          "wgs84": {"lon": \(lon), "lat": \(lat)},
          "results": [
            {"source_id": "tk25-blattschnitt-de", "source_name": "tk25-blattschnitt-de.gpkg",
             "features": [{"id": 0, "layer": "sheets",
                           "properties": {"id": "6326", "dtknummer": "6326", "blattname": "Ochsenfurt"}}]},
            {"source_id": "timezones-2026a", "source_name": "timezones-2026a.gpkg",
             "features": [{"id": 1, "layer": "zones", "properties": {"tzid": "\(zone)"}}]}
          ],
          "gazetteer": {
            "admin": {"country_iso": "DE", "hierarchy": [
              {"level": 8, "name": "Ochsenfurt", "name_native": "", "equivalent": "municipality"},
              {"level": 4, "name": "Bayern", "name_native": "", "equivalent": "state"},
              {"level": 2, "name": "Deutschland", "name_native": "", "equivalent": "country"}
            ]},
            "islands": null, "mountains": null, "bearing": null, "exposure": null,
            "elevation": {"meters": 236.0, "accuracy_m": 4.0, "sea_level": false}
          }
        }
        """
    }
}

/// Records every query and answers with a canned result.
final class StubOrtus: OrtusQuerying, @unchecked Sendable {
    private let result: Result<OrtusResponse, Error>
    private(set) var inputQueries: [CoordinateInput] = []
    private(set) var pointQueries = 0

    init(_ result: Result<OrtusResponse, Error>) {
        self.result = result
    }

    func query(lat _: Double, lon _: Double) async throws -> OrtusResponse {
        pointQueries += 1
        return try result.get()
    }

    func query(input: CoordinateInput) async throws -> OrtusResponse {
        inputQueries.append(input)
        return try result.get()
    }
}
