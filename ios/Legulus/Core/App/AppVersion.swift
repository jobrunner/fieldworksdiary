import Foundation

/// The app's own build identity, read from the bundle at runtime.
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` live in
/// `project.yml` (release-please bumps `MARKETING_VERSION` via its
/// `# x-release-please-version` marker — same `VERSION` file the
/// backend reads at Docker-build time, see `internal/version`).
enum AppVersion {
    /// e.g. "0.1.0"
    static let marketing: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    /// e.g. "1" — bumped per build, not per release.
    static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    /// e.g. "0.1.0 (1)" — for display in Settings/Status.
    static let display = "\(marketing) (\(build))"
}
