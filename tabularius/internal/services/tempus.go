package services

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// TempusResponse is the subset of Tempus' GET /api/v1/query response we
// consume. Unknown fields are ignored.
type TempusResponse struct {
	Query struct {
		Datetime time.Time `json:"datetime"`
	} `json:"query"`
	Features  []TempusFeature  `json:"features"`
	Providers []TempusProvider `json:"providers"`
}

// TempusFeature is one GeoJSON feature (weather, dewpoint, sun, moon,
// aggregate, bioclim). Properties and license are kept as delivered.
type TempusFeature struct {
	Geometry   json.RawMessage `json:"geometry"`
	Properties map[string]any  `json:"properties"`
	License    json.RawMessage `json:"license"`
}

// Kind returns properties.kind, or "" when it is missing.
func (f TempusFeature) Kind() string {
	kind, _ := f.Properties["kind"].(string)
	return kind
}

// Tempus provider states.
const (
	TempusStatusOK          = "ok"
	TempusStatusUnavailable = "unavailable"
	TempusStatusError       = "error"
)

// TempusProvider is the outcome of one provider. Tempus answers 200
// even when a provider failed; the failure is reported here.
type TempusProvider struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Status     string `json:"status"`
	Cached     bool   `json:"cached"`
	Retryable  bool   `json:"retryable"`
	RetryAfter string `json:"retryAfter"`
	Error      string `json:"error"`
}

// RetryAfterDuration parses retryAfter, which Tempus sends as a Go
// duration string ("2h0m0s").
func (p TempusProvider) RetryAfterDuration() (time.Duration, bool) {
	if p.RetryAfter == "" {
		return 0, false
	}
	d, err := time.ParseDuration(p.RetryAfter)
	if err != nil || d <= 0 {
		return 0, false
	}
	return d, true
}

// Tempus wraps the Tempus point-and-time query service (weather,
// climate normals, astronomy). BaseURL is configurable so tests can
// point at a local fake. Logger and Now are optional.
type Tempus struct {
	BaseURL    string
	HTTPClient *http.Client
	Cache      *Geocache
	MaxRetries int
	Logger     *slog.Logger
	Now        func() time.Time
	// FinalAfter is the age from which Tempus answers from the final
	// archive (default 120 h); such answers are cached for FinalMaxAge
	// (default 7 days), younger ones for RecentMaxAge (default 1 h).
	FinalAfter   time.Duration
	FinalMaxAge  time.Duration
	RecentMaxAge time.Duration
}

const (
	tempusService             = "tempus"
	tempusDefaultFinalAfter   = 120 * time.Hour
	tempusDefaultFinalMaxAge  = 7 * 24 * time.Hour
	tempusDefaultRecentMaxAge = time.Hour
)

func (t *Tempus) log() *slog.Logger {
	if t.Logger != nil {
		return t.Logger
	}
	return slog.Default()
}

func (t *Tempus) now() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}

func orDefault(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// cacheMaxAge is how old a cached answer for at may be. Forecast data
// is revised, so an answer for a young instant lives only RecentMaxAge.
// Once the instant is FinalAfter old the archive is final, but only an
// answer fetched after that point holds archive data: an entry cached
// earlier is a forecast answer and must not be served as final.
func (t *Tempus) cacheMaxAge(at time.Time) time.Duration {
	sinceFinal := t.now().Sub(at) - orDefault(t.FinalAfter, tempusDefaultFinalAfter)
	if sinceFinal < 0 {
		return orDefault(t.RecentMaxAge, tempusDefaultRecentMaxAge)
	}
	return min(sinceFinal, orDefault(t.FinalMaxAge, tempusDefaultFinalMaxAge))
}

// Query returns Tempus' answer for (lat, lon) at the instant at. It
// consults the cache first (keyed by coordinate and UTC hour, the
// resolution Tempus works in); on miss it calls the service with retry.
// An answer in which a provider is still unavailable is not cached.
func (t *Tempus) Query(ctx context.Context, lat, lon float64, at time.Time) (*TempusResponse, error) {
	start := time.Now()
	at = at.UTC()
	key := CoordinateKey(lat, lon, at.Truncate(time.Hour).Format(time.RFC3339))

	if t.Cache != nil {
		raw, err := t.Cache.GetMaxAge(tempusService, key, t.cacheMaxAge(at))
		switch {
		case err == nil:
			var resp TempusResponse
			if json.Unmarshal(raw, &resp) == nil {
				t.log().Debug(
					"tempus: query",
					slog.String("service", tempusService),
					slog.String("cache", "hit"),
					slog.Int64("duration_ms", time.Since(start).Milliseconds()),
				)
				return &resp, nil
			}
		case !errors.Is(err, sql.ErrNoRows):
			return nil, fmt.Errorf("cache read: %w", err)
		}
	}

	body, err := t.fetch(ctx, lat, lon, at)
	if err != nil {
		attrs := []any{
			slog.String("service", tempusService),
			slog.String("cache", "miss"),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
		}
		var se *HTTPStatusError
		if errors.As(err, &se) {
			attrs = append(attrs, slog.Int("status", se.StatusCode))
		}
		attrs = append(attrs, slog.Any("err", err))
		t.log().Warn("tempus: query failed", attrs...)
		return nil, err
	}

	var resp TempusResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("decode tempus response: %w", err)
	}

	if t.Cache != nil && !resp.anyUnavailable() {
		// The answer is valid; a failing cache only costs a re-query.
		if err := t.Cache.Put(tempusService, key, body); err != nil {
			t.log().Warn(
				"tempus: cache write failed",
				slog.String("service", tempusService),
				slog.Any("err", err),
			)
		}
	}
	t.log().Info(
		"tempus: query",
		slog.String("service", tempusService),
		slog.String("cache", "miss"),
		slog.Int64("duration_ms", time.Since(start).Milliseconds()),
	)
	return &resp, nil
}

func (r *TempusResponse) anyUnavailable() bool {
	for _, p := range r.Providers {
		if p.Status == TempusStatusUnavailable {
			return true
		}
	}
	return false
}

func (t *Tempus) fetch(ctx context.Context, lat, lon float64, at time.Time) ([]byte, error) {
	q := url.Values{}
	q.Set("lat", strconv.FormatFloat(lat, 'f', 6, 64))
	q.Set("lon", strconv.FormatFloat(lon, 'f', 6, 64))
	q.Set("datetime", at.Format(time.RFC3339))
	full := strings.TrimRight(t.BaseURL, "/") + "/api/v1/query?" + q.Encode()
	return doWithRetry(ctx, t.HTTPClient, http.MethodGet, full, nil, t.MaxRetries)
}
