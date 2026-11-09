import FieldworksGeo
import Foundation
import GRDB

/// CRUD for `local_sample_features`. A sample's feature set is always
/// replaced as a whole (one Ortus response = one complete set), like
/// the backend's `geoplace.ReplaceFeatures`. Rows are wiped together
/// with the samples in `LocalSampleStore.reset()`.
final class LocalSampleFeatureStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Replaces every feature of `sampleID` (local sample UUID) with
    /// `features` in one transaction. An empty list clears the sample.
    func replace(sampleID: String, features: [OrtusFeature]) throws {
        let now = Date()
        try database.writer.write { db in
            _ = try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .deleteAll(db)
            for feature in features {
                var row = LocalSampleFeature(sampleID: sampleID, feature: feature, fetchedAt: now)
                try row.insert(db)
            }
        }
    }

    /// Features of one sample from one Ortus source, in the order they
    /// were stored.
    func features(sampleID: String, sourceID: String) throws -> [LocalSampleFeature] {
        try database.reader.read { db in
            try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(Column("source_id") == sourceID)
                .order(Column.rowID)
                .fetchAll(db)
        }
    }
}
