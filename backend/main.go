package main

import (
	"log"
	"net/http"
	"time"

	"go.mett.io/fwd-backend/internal/api"
	"go.mett.io/fwd-backend/internal/enrichment"
	"go.mett.io/fwd-backend/internal/fusion"
	"go.mett.io/fwd-backend/internal/hooks"
	"go.mett.io/fwd-backend/internal/services"
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
)

const (
	labellocBaseURL = "https://labelloc.example.org"
	mtbBaseURL      = "https://coordstomtb.example.org"
)

func main() {
	app := pocketbase.New()

	// Auto-run Go-based migrations on start.
	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: true,
	})

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

	// Phase 2 + R7.1: async enrichment. Sample-side fills
	// admin_units / mtb / astro on insert; locality-side reverse-
	// geocodes the coordinate into a Placemark row.
	//
	// The cache lives in the `geocache` collection; we hand each
	// enricher a function-bound dao reference because app.Dao() at
	// startup is nil — the dao is built during app.Start().
	httpClient := &http.Client{Timeout: 5 * time.Second}

	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		cache := &services.Geocache{Dao: app.Dao()}
		labelloc := &services.Labelloc{
			BaseURL:    labellocBaseURL,
			HTTPClient: httpClient,
			Cache:      cache,
			MaxRetries: 3,
		}
		enr := &enrichment.Enricher{
			App:      app,
			Labelloc: labelloc,
			MTB: &services.MTB{
				BaseURL:    mtbBaseURL,
				HTTPClient: httpClient,
				Cache:      cache,
				MaxRetries: 3,
			},
			Timeout: 15 * time.Second,
		}
		enr.Register()

		// Phase R7.1: reverse-geocode any locality whose coordinate
		// is set (and re-geocode on a > 100 m shift). Manual-source
		// placemarks are left alone.
		pm := &enrichment.PlacemarkEnricher{
			Labelloc: labelloc,
			Timeout:  15 * time.Second,
		}
		enrichment.RegisterPlacemarkEnricher(app, pm)
		return nil
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
