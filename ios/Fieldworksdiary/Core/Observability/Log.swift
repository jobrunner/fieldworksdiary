import Foundation
import OSLog

/// Zentrale Logger-Instanzen pro Subsystem-Bereich. Feature-Code ruft
/// `Log.sync.info(...)` etc. — kein direktes `Logger(subsystem:category:)`.
///
/// Konvention: siehe `.claude/rules/LOGGING.md`.
enum Log {
    private static let subsystem = "org.fieldworksdiary"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let location = Logger(subsystem: subsystem, category: "Location")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let metrics = Logger(subsystem: subsystem, category: "Metrics")
}
