import Foundation
import MetricKit

/// Empfänger für tägliche `MXMetricPayload` (Performance) und
/// `MXDiagnosticPayload` (Crashes/Hangs/CPU-Exceptions). Loggt die
/// Payloads via `Log.metrics` — damit sind Crash-Reports im
/// Xcode-Organizer **und** in unserer OSLog-Stream-Ansicht sichtbar.
///
/// MetricKit liefert die Reports asynchron, ca. einmal pro Tag, **nach**
/// dem nächsten App-Start. Crashes erscheinen also nicht sofort — das
/// ist Apple-side Drosselung, kein Bug.
@MainActor
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()

    override private init() {
        super.init()
    }

    func register() {
        MXMetricManager.shared.add(self)
        Log.metrics.info("MetricKit subscriber registered")
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // Die Payloads sind groß und enthalten viele Sub-Reports.
            // JSON-Repräsentation in OSLog dumpen ist pragmatisch — die
            // strukturierte Auswertung passiert dann offline mit
            // `log show --predicate ...` oder im Xcode-Organizer.
            let json = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? "<encode-failed>"
            Log.metrics.notice("metric payload: \(json, privacy: .public)")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? "<encode-failed>"
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0

            if crashes > 0 || hangs > 0 || cpu > 0 || disk > 0 {
                Log.metrics.error("""
                diagnostic payload — crashes=\(crashes, privacy: .public) \
                hangs=\(hangs, privacy: .public) cpu=\(cpu, privacy: .public) \
                disk=\(disk, privacy: .public)
                """)
            }
            Log.metrics.notice("diagnostic payload body: \(json, privacy: .public)")
        }
    }
}
