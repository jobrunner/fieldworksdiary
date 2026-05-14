package services

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// LabellocResult is the trimmed shape we keep in samples.admin_units.
// We deliberately ignore the noisy `description` envelope.
type LabellocResult struct {
	Country             string `json:"country"`
	CountryISO          string `json:"countryIso"`
	AdminArea           string `json:"adminArea"`
	AdminArea2          string `json:"adminArea2"`
	AdminArea3          string `json:"adminArea3"`
	Locality            string `json:"locality"`
	LocationDescription string `json:"locationDescription"`
}

type labellocEnvelope struct {
	Result LabellocResult `json:"result"`
	Status struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"status"`
}

// Labelloc wraps the reverse-geocoding service. The base URL is
// configurable so tests can point at a local fake.
type Labelloc struct {
	BaseURL    string
	HTTPClient *http.Client
	Cache      *Geocache
	MaxRetries int
}

const labellocService = "labelloc"

// Lookup returns the location info for (lat, lon). It consults the
// cache first; on miss, calls the upstream service with retry, fixes
// any double-encoded UTF-8 in the response, and writes through to the
// cache.
func (s *Labelloc) Lookup(ctx context.Context, lat, lon float64, lang string) (*LabellocResult, error) {
	if lang == "" {
		lang = "de"
	}
	key := CoordinateKey(lat, lon, lang)

	if s.Cache != nil {
		if raw, err := s.Cache.Get(labellocService, key); err == nil {
			var env labellocEnvelope
			if json.Unmarshal(raw, &env) == nil {
				return &env.Result, nil
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("cache read: %w", err)
		}
	}

	body, err := s.fetch(ctx, lat, lon, lang)
	if err != nil {
		return nil, err
	}
	body = repairDoubleEncodedUTF8(body)

	if s.Cache != nil {
		if err := s.Cache.Put(labellocService, key, body); err != nil {
			return nil, fmt.Errorf("cache write: %w", err)
		}
	}

	var env labellocEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode labelloc response: %w", err)
	}
	if env.Status.Code != 0 && env.Status.Code != 200 {
		return nil, fmt.Errorf("labelloc status %d: %s", env.Status.Code, env.Status.Message)
	}
	return &env.Result, nil
}

func (s *Labelloc) fetch(ctx context.Context, lat, lon float64, lang string) ([]byte, error) {
	u := strings.TrimRight(s.BaseURL, "/") + "/api/location"
	q := url.Values{}
	q.Set("lat", strconv.FormatFloat(lat, 'f', 6, 64))
	q.Set("lon", strconv.FormatFloat(lon, 'f', 6, 64))
	q.Set("lang", lang)
	full := u + "?" + q.Encode()

	return doWithRetry(ctx, s.HTTPClient, http.MethodGet, full, nil, s.MaxRetries)
}

// repairDoubleEncodedUTF8 fixes the labelloc mojibake where a UTF-8
// string was decoded as Latin-1 and then re-encoded as UTF-8: original
// bytes  0xC3 0xXX  ("ü" etc.) became 0xC3 0x83 0xC2 0xXX. The
// transformation is the inverse: any 4-byte run 0xC3 0x83 0xC2 0xYY
// with 0xYY in the Latin-1 supplement range collapses back to
// 0xC3 0xYY. The check is conservative — non-matching byte sequences
// pass through untouched, so calling this on already-clean UTF-8 is a
// no-op.
func repairDoubleEncodedUTF8(b []byte) []byte {
	// Quick reject: the four-byte signature must occur somewhere.
	idx := -1
	for i := 0; i+3 < len(b); i++ {
		if b[i] == 0xC3 && b[i+1] == 0x83 && b[i+2] == 0xC2 {
			idx = i
			break
		}
	}
	if idx < 0 {
		return b
	}

	out := make([]byte, 0, len(b))
	out = append(out, b[:idx]...)
	for i := idx; i < len(b); {
		if i+3 < len(b) && b[i] == 0xC3 && b[i+1] == 0x83 && b[i+2] == 0xC2 {
			yy := b[i+3]
			if yy >= 0x80 && yy <= 0xBF {
				out = append(out, 0xC3, yy)
				i += 4
				continue
			}
		}
		out = append(out, b[i])
		i++
	}
	if !utf8.Valid(out) {
		// Refuse the fix if it produced garbage — keep the original.
		return b
	}
	return out
}

// doWithRetry performs an HTTP request with capped exponential
// backoff. Retries on network errors and 5xx; gives up on 4xx (their
// inputs are wrong, not the network).
func doWithRetry(ctx context.Context, client *http.Client, method, url string, body io.Reader, maxRetries int) ([]byte, error) {
	if maxRetries < 1 {
		maxRetries = 3
	}
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}

	var lastErr error
	delay := 200 * time.Millisecond
	for attempt := 0; attempt < maxRetries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, url, body)
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
		} else {
			data, readErr := io.ReadAll(resp.Body)
			resp.Body.Close()
			if readErr != nil {
				lastErr = readErr
			} else if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				return nil, fmt.Errorf("http %d: %s", resp.StatusCode, truncate(string(data), 200))
			} else if resp.StatusCode >= 500 {
				lastErr = fmt.Errorf("http %d", resp.StatusCode)
			} else {
				return data, nil
			}
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
		delay *= 2
		if delay > 2*time.Second {
			delay = 2 * time.Second
		}
	}
	return nil, fmt.Errorf("gave up after %d attempts: %w", maxRetries, lastErr)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
