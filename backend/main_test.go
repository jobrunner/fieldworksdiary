package main

import (
	"errors"
	"net/http"
	"testing"

	"github.com/pocketbase/pocketbase/tests"
)

func newMainTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

func TestNewBackfillRunner_MissingOrtusURLIsError(t *testing.T) {
	app := newMainTestApp(t)
	if _, err := newBackfillRunner(app, http.DefaultClient, "  ", false); !errors.Is(err, errNoOrtusURL) {
		t.Fatalf("err = %v, want errNoOrtusURL", err)
	}
}

func TestNewBackfillRunner_RemapOnlyWithoutOrtusURL(t *testing.T) {
	app := newMainTestApp(t)
	r, err := newBackfillRunner(app, http.DefaultClient, "", true)
	if err != nil {
		t.Fatalf("remap-only must work without ORTUS_BASE_URL: %v", err)
	}
	if r.Enricher.Ortus != nil || r.Localities.Ortus != nil {
		t.Error("ortus client set without URL")
	}
}

func TestNewBackfillRunner_WiresOrtusForSamplesAndLocalities(t *testing.T) {
	app := newMainTestApp(t)
	r, err := newBackfillRunner(app, http.DefaultClient, "https://ortus.example.org", false)
	if err != nil {
		t.Fatal(err)
	}
	if r.Enricher.Ortus == nil || r.Localities.Ortus != r.Enricher.Ortus ||
		r.Enricher.Ortus.BaseURL != "https://ortus.example.org" {
		t.Error("ortus client not wired into both enrichers")
	}
}
