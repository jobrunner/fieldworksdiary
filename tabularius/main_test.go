package main

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"go.mett.io/tabularius/internal/testutil"

	"github.com/pocketbase/pocketbase/tests"
)

func newMainTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app := testutil.NewTestApp(t)
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

func TestNewConditionsBackfillRunner_MissingTempusURLIsError(t *testing.T) {
	app := testutil.NewTestApp(t)
	if _, err := newConditionsBackfillRunner(app, http.DefaultClient, "  ", 0, 0); !errors.Is(err, errNoTempusURL) {
		t.Fatalf("err = %v, want errNoTempusURL", err)
	}
}

func TestNewConditionsBackfillRunner_WiresTempusAndFlags(t *testing.T) {
	app := testutil.NewTestApp(t)
	r, err := newConditionsBackfillRunner(app, http.DefaultClient, " https://tempus.example ", 50, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if r.Conditions == nil || r.Conditions.Tempus == nil || r.Conditions.Tempus.BaseURL != "https://tempus.example" {
		t.Fatalf("tempus not wired: %+v", r.Conditions)
	}
	if r.Conditions.Tempus.Cache == nil {
		t.Error("tempus client without cache")
	}
	if r.Limit != 50 || r.Interval != 3*time.Second {
		t.Errorf("limit %d, interval %s", r.Limit, r.Interval)
	}
}
