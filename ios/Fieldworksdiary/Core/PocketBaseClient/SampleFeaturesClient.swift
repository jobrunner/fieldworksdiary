import FieldworksGeo
import Foundation

/// One `sample_features` record as delivered by the server. `sample`
/// is the backend sample id; `propertiesJSON` / `licenseJSON` are the
/// raw JSON of the two JSON columns.
struct RemoteSampleFeature: Equatable {
    let id: String
    let sample: String
    let sourceID: String
    let sourceName: String
    let layer: String
    let featureID: String
    let propertiesJSON: String
    let licenseJSON: String?

    /// Same shape the on-device resolver stores, so both paths share
    /// `LocalSampleFeatureStore.replace`.
    var ortusFeature: OrtusFeature {
        OrtusFeature(sourceID: sourceID, sourceName: sourceName, layer: layer,
                     featureID: featureID, propertiesJSON: propertiesJSON, licenseJSON: licenseJSON)
    }

    /// Parses one list item. Returns nil for items without id/sample.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty,
              let sample = json["sample"] as? String, !sample.isEmpty
        else { return nil }
        self.id = id
        self.sample = sample
        sourceID = json["source_id"] as? String ?? ""
        sourceName = json["source_name"] as? String ?? ""
        layer = json["layer"] as? String ?? ""
        featureID = json["feature_id"] as? String ?? ""
        propertiesJSON = Self.serialize(json["properties"]) ?? "{}"
        licenseJSON = Self.serialize(json["license"])
    }

    init(id: String, sample: String, sourceID: String, sourceName: String, layer: String,
         featureID: String, propertiesJSON: String, licenseJSON: String?)
    {
        self.id = id
        self.sample = sample
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.layer = layer
        self.featureID = featureID
        self.propertiesJSON = propertiesJSON
        self.licenseJSON = licenseJSON
    }

    private static func serialize(_ value: Any?) -> String? {
        guard let value, !(value is NSNull),
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What the sync layer needs from the sample-features API.
/// `SampleFeaturesClient` conforms; tests inject a mock.
protocol SampleFeaturesSyncClient {
    /// `PUT /api/samples/:id/features` — replaces the server's complete
    /// feature set of the sample (an empty list clears it).
    func replaceFeatures(sampleBackendID: String, features: [LocalSampleFeature]) async throws
    /// Features of the given backend samples, all pages.
    func fetchFeatures(sampleBackendIDs: [String]) async throws -> [RemoteSampleFeature]
}

/// Client for `sample_features` (Phase O): the replace endpoint from
/// `backend/internal/api/sample_features.go` and the owner-scoped
/// records list.
struct SampleFeaturesClient: SampleFeaturesSyncClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Request body `{"features": [...]}`. The `features` key is always
    /// present (the server answers 400 without it). Properties and
    /// license go out as JSON values, not strings; a feature whose
    /// stored properties are not a JSON object gets `{}`.
    static func replaceBody(_ features: [LocalSampleFeature]) -> [String: Any] {
        let items: [[String: Any]] = features.map { f in
            var item: [String: Any] = [
                "source_id": f.sourceID,
                "source_name": f.sourceName,
                "layer": f.layer,
                "feature_id": f.featureID,
                "properties": jsonValue(f.propertiesJSON) as? [String: Any] ?? [String: Any]()
            ]
            if let license = f.licenseJSON.flatMap(jsonValue) {
                item["license"] = license
            }
            return item
        }
        return ["features": items]
    }

    func replaceFeatures(sampleBackendID: String, features: [LocalSampleFeature]) async throws {
        let url = try makeURL(path: "/api/samples/\(sampleBackendID)/features")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.replaceBody(features))
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    func fetchFeatures(sampleBackendIDs: [String]) async throws -> [RemoteSampleFeature] {
        let safe = sampleBackendIDs.filter(PlacemarkClient.isRecordID)
        if safe.isEmpty { return [] }
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        let filter = safe.map { "sample='\($0)'" }.joined(separator: " || ")

        var result: [RemoteSampleFeature] = []
        var page = 1
        while true {
            var components = URLComponents(string: trimmed.appending("/api/collections/sample_features/records"))
            components?.queryItems = [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "perPage", value: "500"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components?.url else { throw SampleClientError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.authenticate(with: auth)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200 ..< 300).contains(status) else {
                throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SampleClientError.decoding("sample_features list")
            }
            result.append(contentsOf: items.compactMap(RemoteSampleFeature.init(json:)))
            let totalPages = json["totalPages"] as? Int ?? page
            if page >= totalPages || items.isEmpty { break }
            page += 1
        }
        return result
    }

    private func makeURL(path: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        return url
    }
}

private func jsonValue(_ raw: String) -> Any? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
