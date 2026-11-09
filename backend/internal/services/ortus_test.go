package services

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	_ "go.mett.io/fwd-backend/migrations"
)

func newTestGeocache(t *testing.T) *Geocache {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return &Geocache{Dao: app.Dao()}
}

func ortusFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "ortus", name))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return b
}

func TestOrtusQuery_DecodesDE(t *testing.T) {
	body := ortusFixture(t, "query_de_ochsenfurt.json")
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query" {
			http.NotFound(w, r)
			return
		}
		gotQuery = r.URL.RawQuery
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := o.Query(context.Background(), 49.681616, 10.039652)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if gotQuery != "lat=49.681616&lon=10.039652" {
		t.Errorf("unexpected query %q", gotQuery)
	}
	if got.Gazetteer == nil || got.Gazetteer.Admin == nil {
		t.Fatalf("gazetteer/admin missing: %+v", got.Gazetteer)
	}
	adm := got.Gazetteer.Admin
	if adm.CountryISO != "DE" {
		t.Errorf("country_iso = %q", adm.CountryISO)
	}
	if len(adm.Hierarchy) != 5 || adm.Hierarchy[0].Name != "Ochsenfurt" || adm.Hierarchy[0].Level != 8 {
		t.Errorf("hierarchy = %+v", adm.Hierarchy)
	}
	if adm.Hierarchy[1].Equivalent != "county" || adm.Hierarchy[0].LocalTerm != "Stadt / Gemeinde" {
		t.Errorf("hierarchy terms = %+v", adm.Hierarchy)
	}
	found := false
	for _, r := range got.Results {
		if r.SourceID != "tk25-blattschnitt-de" {
			continue
		}
		for _, f := range r.Features {
			if f.Properties["dtknummer"] == "6326" && f.Properties["id"] == "6326" {
				found = true
			}
		}
	}
	if !found {
		t.Errorf("tk25 feature not found in %+v", got.Results)
	}
	g := got.Gazetteer
	if g.Bearing == nil || g.Bearing.Label != "2 km WNW Ochsenfurt" || g.Bearing.DistanceKm != 2.3 {
		t.Errorf("bearing = %+v", g.Bearing)
	}
	if g.Exposure == nil || g.Exposure.AspectDeg == nil || *g.Exposure.AspectDeg != 202.5 || g.Exposure.AspectCompass != "SSW" {
		t.Errorf("exposure = %+v", g.Exposure)
	}
	if g.Elevation == nil || g.Elevation.Meters != 236.0 || g.Elevation.SeaLevel {
		t.Errorf("elevation = %+v", g.Elevation)
	}
	if got.WGS84 == nil || got.WGS84.Lat != 49.681616 {
		t.Errorf("wgs84 = %+v", got.WGS84)
	}
}

func TestOrtusQuery_DecodesIslandsAndMountains(t *testing.T) {
	body := ortusFixture(t, "query_es_lapalma.json")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(body) }))
	defer srv.Close()

	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := o.Query(context.Background(), 28.6835, -17.7642)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	g := got.Gazetteer
	if len(g.Islands) != 1 || g.Islands[0].Name != "La Palma" {
		t.Errorf("islands = %+v", g.Islands)
	}
	if g.Mountains == nil || g.Mountains.Mountain == nil || g.Mountains.Mountain.Name != "Pico Bejenado" || g.Mountains.Range != nil {
		t.Errorf("mountains = %+v", g.Mountains)
	}
	if g.Admin.CountryISO != "ES" || len(g.Admin.Hierarchy) != 4 {
		t.Errorf("admin = %+v", g.Admin)
	}
}

func TestOrtusQuery_SeaPointAdminNil(t *testing.T) {
	body := ortusFixture(t, "query_sea.json")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(body) }))
	defer srv.Close()

	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := o.Query(context.Background(), 40, -25)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if got.Gazetteer == nil {
		t.Fatal("gazetteer nil")
	}
	g := got.Gazetteer
	if g.Admin != nil || g.Islands != nil || g.Mountains != nil || g.Bearing != nil || g.Exposure != nil || g.Elevation != nil {
		t.Errorf("expected all-nil gazetteer blocks, got %+v", g)
	}
	if len(got.Results) != 0 {
		t.Errorf("results = %+v", got.Results)
	}
}

func TestOrtusQuery_5xxRetriesThenErrors(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	o := &Ortus{BaseURL: srv.URL, MaxRetries: 2}
	if _, err := o.Query(context.Background(), 49.7, 10.0); err == nil {
		t.Fatal("expected error")
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Errorf("expected 2 attempts, got %d", n)
	}
}

func TestOrtusQuery_CachesSecondCall(t *testing.T) {
	body := ortusFixture(t, "query_de_ochsenfurt.json")
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	cache := newTestGeocache(t)
	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1, Cache: cache}
	for i := 0; i < 2; i++ {
		got, err := o.Query(context.Background(), 49.681616, 10.039652)
		if err != nil {
			t.Fatalf("Query #%d: %v", i, err)
		}
		if got.Gazetteer == nil || got.Gazetteer.Admin == nil || got.Gazetteer.Admin.CountryISO != "DE" {
			t.Fatalf("call #%d bad decode", i)
		}
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Errorf("server hits = %d, want 1", n)
	}
}

// bufLogger returns a JSON slog logger writing into the returned buffer.
func bufLogger() (*slog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	return slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})), &buf
}

func assertNoCoordinates(t *testing.T, what, s string) {
	t.Helper()
	for _, leak := range []string{"lat=", "lon=", "49.681616", "10.039652", "49.68", "10.03"} {
		if strings.Contains(s, leak) {
			t.Errorf("%s leaks %q: %s", what, leak, s)
		}
	}
}

func TestOrtusQuery_UnreachableErrorHasNoCoordinates(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	base := srv.URL
	srv.Close() // connection refused from now on

	logger, logs := bufLogger()
	o := &Ortus{BaseURL: base, MaxRetries: 1, Logger: logger}
	_, err := o.Query(context.Background(), 49.681616, 10.039652)
	if err == nil {
		t.Fatal("expected error")
	}
	assertNoCoordinates(t, "error", err.Error())
	assertNoCoordinates(t, "log", logs.String())
	if !strings.Contains(err.Error(), "/api/v1/query") {
		t.Errorf("error should still name the path: %v", err)
	}
}

func TestOrtusQuery_4xxErrorOmitsBodyAndLogsStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A service that echoes the query in its error body.
		http.Error(w, "bad point lat=49.681616 lon=10.039652", http.StatusBadRequest)
	}))
	defer srv.Close()

	logger, logs := bufLogger()
	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1, Logger: logger}
	_, err := o.Query(context.Background(), 49.681616, 10.039652)
	if err == nil {
		t.Fatal("expected error")
	}
	assertNoCoordinates(t, "error", err.Error())
	assertNoCoordinates(t, "log", logs.String())
	var se *HTTPStatusError
	if !errors.As(err, &se) || se.StatusCode != http.StatusBadRequest {
		t.Errorf("err = %v, want HTTPStatusError 400", err)
	}
	if !strings.Contains(logs.String(), `"status":400`) {
		t.Errorf("log lacks status code: %s", logs.String())
	}
}

func TestOrtusQuery_5xxLogsStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusBadGateway)
	}))
	defer srv.Close()

	logger, logs := bufLogger()
	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1, Logger: logger}
	if _, err := o.Query(context.Background(), 49.681616, 10.039652); err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(logs.String(), `"status":502`) {
		t.Errorf("log lacks status code: %s", logs.String())
	}
}

func TestOrtusQuery_CacheWriteErrorStillReturnsResponse(t *testing.T) {
	body := ortusFixture(t, "query_de_ochsenfurt.json")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	app.OnModelBeforeCreate("geocache").Add(func(*core.ModelEvent) error {
		return errors.New("disk full")
	})

	logger, logs := bufLogger()
	o := &Ortus{BaseURL: srv.URL, MaxRetries: 1, Cache: &Geocache{Dao: app.Dao()}, Logger: logger}
	got, err := o.Query(context.Background(), 49.681616, 10.039652)
	if err != nil {
		t.Fatalf("Query: %v, want response despite cache write error", err)
	}
	if got.Gazetteer == nil || got.Gazetteer.Admin == nil || got.Gazetteer.Admin.CountryISO != "DE" {
		t.Fatalf("bad decode: %+v", got.Gazetteer)
	}
	if !strings.Contains(logs.String(), `"level":"WARN"`) ||
		!strings.Contains(logs.String(), `"service":"ortus"`) ||
		!strings.Contains(logs.String(), "cache write") {
		t.Errorf("missing cache-write warning: %s", logs.String())
	}
}
