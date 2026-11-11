import FieldworksGeo
import Foundation
import GRDB

/// One Ortus source feature (protected area, habitat, …) at a
/// sample's coordinate. Local twin of the backend `sample_features`
/// collection; `sampleID` is the *local* sample UUID
/// (`LocalSample.id`), not the sample code.
struct LocalSampleFeature: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var sampleID: String
    var sourceID: String
    var sourceName: String
    var layer: String
    var featureID: String
    /// Raw JSON object of the feature's properties.
    var propertiesJSON: String
    /// Raw JSON of the source license, if Ortus delivered one.
    var licenseJSON: String?
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, layer
        case sampleID = "sample_id"
        case sourceID = "source_id"
        case sourceName = "source_name"
        case featureID = "feature_id"
        case propertiesJSON = "properties_json"
        case licenseJSON = "license_json"
        case fetchedAt = "fetched_at"
    }

    static let databaseTableName = "local_sample_features"
}

extension LocalSampleFeature {
    init(sampleID: String, feature: OrtusFeature, fetchedAt: Date) {
        id = UUID().uuidString
        self.sampleID = sampleID
        sourceID = feature.sourceID
        sourceName = feature.sourceName
        layer = feature.layer
        featureID = feature.featureID
        propertiesJSON = feature.propertiesJSON
        licenseJSON = feature.licenseJSON
        self.fetchedAt = fetchedAt
    }
}
