package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/api"
	"go.mett.io/fwd-backend/internal/enrichment"
	"go.mett.io/fwd-backend/internal/fusion"
	"go.mett.io/fwd-backend/internal/hooks"
	"go.mett.io/fwd-backend/internal/services"
	"go.mett.io/fwd-backend/internal/version"
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
)

// defaultAppleAudiences are the iOS bundle ids the native Sign in
// with Apple flow may legitimately produce identityTokens for. The
// `APPLE_ALLOWED_AUDIENCES` env var (comma-separated) overrides this
// list — useful for staging environments with their own bundle ids.
var defaultAppleAudiences = []string{
	"org.fieldworksdiary.dev",
	"org.fieldworksdiary.staging",
	"org.fieldworksdiary.prod",
}

func resolveAppleAudiences() []string {
	raw := strings.TrimSpace(os.Getenv("APPLE_ALLOWED_AUDIENCES"))
	if raw == "" {
		return defaultAppleAudiences
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	if len(out) == 0 {
		return defaultAppleAudiences
	}
	return out
}

func main() {
	// JSON-Output, weil PocketBase in Docker läuft → Logs gehen über
	// Docker-Driver in ELK/Loki/whatever. Kein Text-Format mit Farben.
	// Siehe .claude/rules/LOGGING.md. Debug-Level nur mit PB_LOG_LEVEL=debug.
	logLevel := slog.LevelInfo
	if strings.EqualFold(os.Getenv("PB_LOG_LEVEL"), "debug") {
		logLevel = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level:     logLevel,
		AddSource: false,
	})))

	app := pocketbase.New()

	slog.Info("starting fieldworksdiary",
		slog.String("version", version.Version),
		slog.String("commit", version.Commit),
	)

	// Auto-run Go-based migrations on start.
	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: true,
	})

	// Public build-identity endpoint — the iOS "Status" screen shows
	// this next to the app's own version.
	api.RegisterVersionRoute(app)

	// Phase 1: code-vergabe + auto-grouping on sample insert.
	hooks.RegisterSampleCreate(app)

	// Phase 11a: fill `owner` from the authenticated user on the
	// other user-facing collections.
	hooks.RegisterOwnerSetters(app)

	// Phase R5.1: optimistic-concurrency guard on the versioned
	// collections (samples, fieldtrips, localities). Stale writes
	// get 409; happy-path writes have their `version` rewritten
	// to the canonical post-write counter.
	hooks.RegisterVersionConflictGuards(app)

	// Phase O: samples/localities may only reference placemarks the
	// caller can see (shared backend rows or own manual rows).
	hooks.RegisterPlacemarkRefGuards(app)

	// Phase O: a coordinate move on a backend_service sample without a
	// client-resolved placemark resets location_status to pending, so
	// the async enrichment re-resolves the place.
	hooks.RegisterSampleLocationReset(app)

	// Phase R6.1: server-side locality fusion. Every locality
	// create + every centroid-shift > 100 m triggers ServerFuse;
	// the hook merges duplicates (with a remap-event emit) or
	// flags ambiguous neighbors for review.
	hooks.RegisterLocalityFusion(app, fusion.Settings{})

	// Phase 7: custom label-PDF endpoints.
	api.RegisterLabelRoutes(app)

	// Phase 10: backup/export endpoint (ZIP with all owner-records
	// plus attached PDFs).
	api.RegisterExportRoute(app)

	// Phase R7.2: manual-override endpoints for Locality.placemark.
	// PATCH sets a `geocoding_source = manual` placemark; DELETE
	// clears it so the next coord tick re-runs the auto-geocoder.
	api.RegisterPlacemarkOverrideRoutes(app)
	api.RegisterPlacemarkResolveRoute(app)
	api.RegisterSampleFeaturesRoute(app)

	// Phase R8: native Sign in with Apple. Verifies the iOS-issued
	// identityToken against Apple's JWKS, links the user by the
	// stable `sub` claim, and returns a PB auth token in the same
	// shape as the other auth endpoints.
	api.RegisterAppleNativeSignIn(app, services.NewAppleVerifier(resolveAppleAudiences()))

	// Phase 2 + R7.1 + O: async enrichment. Sample-side queries Ortus
	// for placemark / features / MTB / terrain on insert and coordinate
	// change (ORTUS_BASE_URL; empty disables it) and recomputes the
	// fieldtrip astro; locality-side reverse-geocodes the coordinate
	// into a Placemark row.
	//
	// The cache lives in the `geocache` collection; we hand each
	// enricher a function-bound dao reference because app.Dao() at
	// startup is nil — the dao is built during app.Start().
	httpClient := &http.Client{Timeout: 5 * time.Second}

	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		cache := &services.Geocache{Dao: app.Dao()}
		enr := &enrichment.Enricher{
			App:     app,
			Labels:  adminlabels.Default(),
			Logger:  slog.Default(),
			Timeout: 15 * time.Second,
		}
		if ortusBaseURL := strings.TrimSpace(os.Getenv("ORTUS_BASE_URL")); ortusBaseURL != "" {
			enr.Ortus = &services.Ortus{
				BaseURL:    ortusBaseURL,
				HTTPClient: httpClient,
				Cache:      cache,
				MaxRetries: 3,
				Logger:     slog.Default(),
			}
		} else {
			slog.Warn("ortus: ORTUS_BASE_URL leer, Anreicherung deaktiviert")
		}
		enr.Register()

		// Reverse-geocode any locality whose coordinate is set (and
		// re-geocode on a > 100 m shift) via the same Ortus client.
		// Manual-source placemarks are left alone; without an Ortus
		// client the enricher does nothing.
		pm := &enrichment.PlacemarkEnricher{
			Ortus:   enr.Ortus,
			Labels:  adminlabels.Default(),
			Logger:  slog.Default(),
			Timeout: 15 * time.Second,
		}
		enrichment.RegisterPlacemarkEnricher(app, pm)
		return nil
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
