// Package version holds the build-time-injected version identity of
// the backend binary. Values are set via `-ldflags "-X ..."` at build
// time (see backend/Dockerfile); running via `go run .` or `go test`
// without that flag falls back to the zero-values below, which is
// intentional — it makes an unversioned dev build obvious instead of
// silently claiming to be a release.
package version

var (
	// Version is the monorepo-wide semver string from the root
	// `VERSION` file (single source of truth for backend + iOS,
	// bumped by release-please — see release-please-config.json).
	Version = "dev"
	// Commit is the short git SHA the binary was built from.
	Commit = "unknown"
)

// Info is the JSON shape returned by GET /api/version.
type Info struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
}

// Current returns the process's build identity.
func Current() Info {
	return Info{Version: Version, Commit: Commit}
}
