package main

import (
	"log"
	"net/http"
	"time"

	"go.mett.io/fwd-backend/internal/api"
	"go.mett.io/fwd-backend/internal/enrichment"
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

	// Phase 7: custom label-PDF endpoints.
	api.RegisterLabelRoutes(app)

	// Phase 10: backup/export endpoint (ZIP with all owner-records
	// plus attached PDFs).
	api.RegisterExportRoute(app)

	// Phase 2: async enrichment of samples with labelloc + MTB. The
	// cache lives in the `geocache` collection; we hand the enricher
	// a function-bound dao reference because app.Dao() at startup is
	// nil — the dao is built during app.Start().
	httpClient := &http.Client{Timeout: 5 * time.Second}

	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		cache := &services.Geocache{Dao: app.Dao()}
		enr := &enrichment.Enricher{
			App: app,
			Labelloc: &services.Labelloc{
				BaseURL:    labellocBaseURL,
				HTTPClient: httpClient,
				Cache:      cache,
				MaxRetries: 3,
			},
			MTB: &services.MTB{
				BaseURL:    mtbBaseURL,
				HTTPClient: httpClient,
				Cache:      cache,
				MaxRetries: 3,
			},
			Timeout: 15 * time.Second,
		}
		enr.Register()
		return nil
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
