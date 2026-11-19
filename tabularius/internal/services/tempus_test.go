package services_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"go.mett.io/tabularius/internal/services"
)

func tempusFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "tempus", name))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return b
}

// tempusServer serves one fixture and counts the requests.
func tempusServer(t *testing.T, body []byte, hits *int32, lastQuery *string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query" {
			http.NotFound(w, r)
			return
		}
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		if lastQuery != nil {
			*lastQuery = r.URL.RawQuery
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

var tempusPast = time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)

func TestTempusQuery_DecodesAllKinds(t *testing.T) {
	var query string
	srv := tempusServer(t, tempusFixture(t, "query_past_all_ok.json"), nil, &query)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if query != "datetime=2026-07-01T12%3A00%3A00Z&lat=48.135100&lon=11.582000" {
		t.Errorf("unexpected query %q", query)
	}
	kinds := map[string]bool{}
	for _, f := range got.Features {
		kinds[f.Kind()] = true
		if len(f.License) == 0 {
			t.Errorf("feature %s without license", f.Kind())
		}
	}
	for _, k := range []string{"weather", "dewpoint", "sun", "moon", "aggregate", "bioclim"} {
		if !kinds[k] {
			t.Errorf("kind %s missing", k)
		}
	}
	if len(got.Features) != 6 || len(got.Providers) != 6 {
		t.Errorf("features = %d, providers = %d", len(got.Features), len(got.Providers))
	}
	for _, p := range got.Providers {
		if p.Status != "ok" {
			t.Errorf("provider %s status %q", p.ID, p.Status)
		}
	}
	if !got.Query.Datetime.Equal(tempusPast) {
		t.Errorf("query datetime = %s", got.Query.Datetime)
	}
}

func TestTempusQuery_RetryAfterDuration(t *testing.T) {
	srv := tempusServer(t, tempusFixture(t, "query_recent_weather_unavailable.json"), nil, nil)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	var seen bool
	for _, p := range got.Providers {
		if p.ID != "open-meteo" {
			continue
		}
		seen = true
		d, ok := p.RetryAfterDuration()
		if p.Status != "unavailable" || !p.Retryable || !ok || d != 2*time.Hour {
			t.Errorf("provider = %+v, duration %s ok=%v", p, d, ok)
		}
	}
	if !seen {
		t.Fatal("open-meteo provider missing")
	}
	if _, ok := (services.TempusProvider{RetryAfter: "bald"}).RetryAfterDuration(); ok {
		t.Error("unparseable retryAfter must report !ok")
	}
	if _, ok := (services.TempusProvider{}).RetryAfterDuration(); ok {
		t.Error("empty retryAfter must report !ok")
	}
}

func TestTempusQuery_FutureKeepsSunAndMoon(t *testing.T) {
	srv := tempusServer(t, tempusFixture(t, "query_future_weather_error.json"), nil, nil)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1}
	got, err := tp.Query(context.Background(), 48.1351, 11.582, time.Date(2027, 6, 1, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	kinds := map[string]bool{}
	for _, f := range got.Features {
		kinds[f.Kind()] = true
	}
	if !kinds["sun"] || !kinds["moon"] || kinds["weather"] {
		t.Errorf("kinds = %v", kinds)
	}
}

func TestTempusQuery_CachesFinalAnswer(t *testing.T) {
	var hits int32
	srv := tempusServer(t, tempusFixture(t, "query_past_all_ok.json"), &hits, nil)
	now := tempusPast.Add(30 * 24 * time.Hour)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1, Cache: newTestGeocache(t), Now: func() time.Time { return now }}
	for i := 0; i < 2; i++ {
		// Same hour and same place to 5 decimals: one cache entry.
		if _, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast.Add(time.Duration(i)*20*time.Minute)); err != nil {
			t.Fatalf("Query %d: %v", i, err)
		}
	}
	if hits != 1 {
		t.Errorf("server hits = %d, want 1", hits)
	}
	// Another hour is another entry.
	if _, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if hits != 2 {
		t.Errorf("server hits = %d, want 2", hits)
	}
}

func TestTempusQuery_DoesNotCacheUnavailable(t *testing.T) {
	var hits int32
	srv := tempusServer(t, tempusFixture(t, "query_recent_weather_unavailable.json"), &hits, nil)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1, Cache: newTestGeocache(t)}
	for i := 0; i < 2; i++ {
		if _, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast); err != nil {
			t.Fatalf("Query %d: %v", i, err)
		}
	}
	if hits != 2 {
		t.Errorf("server hits = %d, want 2", hits)
	}
}

func TestTempusQuery_RecentAnswerExpiresAfterOneHour(t *testing.T) {
	var hits int32
	srv := tempusServer(t, tempusFixture(t, "query_past_all_ok.json"), &hits, nil)
	// The queried instant is only a day old: forecast data.
	now := tempusPast.Add(24 * time.Hour)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1, Cache: newTestGeocache(t), Now: func() time.Time { return now }}
	q := func() {
		t.Helper()
		if _, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast); err != nil {
			t.Fatal(err)
		}
	}
	q()
	q()
	if hits != 1 {
		t.Fatalf("server hits = %d, want 1 within the hour", hits)
	}
	// The cache row's age is measured on the wall clock; a zero max age
	// stands in for "an hour later".
	tp.RecentMaxAge = time.Nanosecond
	time.Sleep(2 * time.Millisecond)
	q()
	if hits != 2 {
		t.Errorf("server hits = %d, want 2 after expiry", hits)
	}
}

func TestTempusQuery_ErrorHidesURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1}
	_, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast)
	if err == nil {
		t.Fatal("expected an error")
	}
	host := strings.TrimPrefix(srv.URL, "http://")
	if strings.Contains(err.Error(), "lat=") || strings.Contains(err.Error(), host) || strings.Contains(err.Error(), "48.13") {
		t.Errorf("error leaks request details: %v", err)
	}
}

func TestTempusQuery_BrokenJSONIsAnError(t *testing.T) {
	srv := tempusServer(t, []byte("{"), nil, nil)
	tp := &services.Tempus{BaseURL: srv.URL, MaxRetries: 1}
	if _, err := tp.Query(context.Background(), 48.1351, 11.582, tempusPast); err == nil {
		t.Fatal("expected a decode error")
	}
}

func TestGeocacheGetMaxAge(t *testing.T) {
	c := newTestGeocache(t)
	if err := c.Put("tempus", "k", []byte(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	if got, err := c.GetMaxAge("tempus", "k", time.Hour); err != nil || string(got) != `{"a":1}` {
		t.Errorf("fresh entry: %q, %v", got, err)
	}
	time.Sleep(2 * time.Millisecond)
	if _, err := c.GetMaxAge("tempus", "k", time.Nanosecond); err == nil {
		t.Error("expired entry must not be returned")
	}
	if got, err := c.Get("tempus", "k"); err != nil || len(got) == 0 {
		t.Errorf("Get with the default TTL: %q, %v", got, err)
	}
}
