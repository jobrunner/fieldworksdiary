package services

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// MTBResult is the trimmed shape we keep in samples.mtb. Boundaries
// are kept verbatim so the iOS map can use them later.
type MTBResult struct {
	SheetNumber     string         `json:"sheet_number"`
	SheetName       string         `json:"sheet_name"`
	Quadrant        int            `json:"quadrant"`
	QuadrantRow     int            `json:"quadrant_row,omitempty"`
	QuadrantColumn  int            `json:"quadrant_column,omitempty"`
	Found           bool           `json:"found"`
	SheetBoundaries map[string]any `json:"sheet_boundaries,omitempty"`
}

type mtbEnvelope struct {
	Result MTBResult `json:"result"`
	Status struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"status"`
}

// MTB wraps the Messtischblatt-lookup service. Outside Germany the
// service typically reports `found:false`; we treat that as a
// successful lookup with an empty result, never as an error.
type MTB struct {
	BaseURL    string
	HTTPClient *http.Client
	Cache      *Geocache
	MaxRetries int
}

const mtbService = "mtb"

// Lookup returns the MTB info for (lat, lon). Outside DE the result's
// `Found` field is false — the caller decides whether to persist
// anything in that case.
func (s *MTB) Lookup(ctx context.Context, lat, lon float64) (*MTBResult, error) {
	key := CoordinateKey(lat, lon, "")

	if s.Cache != nil {
		if raw, err := s.Cache.Get(mtbService, key); err == nil {
			var env mtbEnvelope
			if json.Unmarshal(raw, &env) == nil {
				return &env.Result, nil
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("cache read: %w", err)
		}
	}

	body, err := s.fetch(ctx, lat, lon)
	if err != nil {
		return nil, err
	}

	if s.Cache != nil {
		if err := s.Cache.Put(mtbService, key, body); err != nil {
			return nil, fmt.Errorf("cache write: %w", err)
		}
	}

	var env mtbEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode mtb response: %w", err)
	}
	if env.Status.Code != 0 && env.Status.Code != 200 {
		return nil, fmt.Errorf("mtb status %d: %s", env.Status.Code, env.Status.Message)
	}
	return &env.Result, nil
}

func (s *MTB) fetch(ctx context.Context, lat, lon float64) ([]byte, error) {
	u := strings.TrimRight(s.BaseURL, "/") + "/api/coordinate"
	q := url.Values{}
	q.Set("lat", strconv.FormatFloat(lat, 'f', 6, 64))
	q.Set("lon", strconv.FormatFloat(lon, 'f', 6, 64))
	full := u + "?" + q.Encode()

	return doWithRetry(ctx, s.HTTPClient, http.MethodGet, full, nil, s.MaxRetries)
}
