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

// OrtusResponse is the subset of Ortus' GET /api/v1/query response we
// consume (with the gazetteer block). Unknown fields are ignored.
type OrtusResponse struct {
	WGS84 *struct {
		Lon float64 `json:"lon"`
		Lat float64 `json:"lat"`
	} `json:"wgs84"`
	Results   []OrtusSourceResult `json:"results"`
	Gazetteer *OrtusGazetteer     `json:"gazetteer"`
}

// OrtusSourceResult holds the features one loaded source returned for
// the query point.
type OrtusSourceResult struct {
	SourceID   string          `json:"source_id"`
	SourceName string          `json:"source_name"`
	Features   []OrtusFeature  `json:"features"`
	License    json.RawMessage `json:"license"`
}

// OrtusFeature is a single feature. ID stays raw because Ortus ids can
// be numbers or strings.
type OrtusFeature struct {
	ID         json.RawMessage `json:"id"`
	Layer      string          `json:"layer"`
	Properties map[string]any  `json:"properties"`
}

// OrtusGazetteer is the gazetteer block. Every optional part is nil
// when Ortus has no result for the point (e.g. open sea).
type OrtusGazetteer struct {
	Admin *struct {
		CountryISO string           `json:"country_iso"`
		Hierarchy  []OrtusAdminUnit `json:"hierarchy"` // most-local first
	} `json:"admin"`
	Islands   []OrtusNamed `json:"islands"`
	Mountains *struct {
		Mountain *OrtusNamed `json:"mountain"`
		Range    *OrtusNamed `json:"range"`
	} `json:"mountains"`
	Bearing   *OrtusBearing   `json:"bearing"`
	Exposure  *OrtusExposure  `json:"exposure"`
	Elevation *OrtusElevation `json:"elevation"`
}

// OrtusAdminUnit is one level of the administrative hierarchy.
type OrtusAdminUnit struct {
	Level      int    `json:"level"`
	Name       string `json:"name"`
	NameNative string `json:"name_native"`
	Equivalent string `json:"equivalent"`
	LocalTerm  string `json:"local_term"`
}

// OrtusNamed is a named island, mountain or range.
type OrtusNamed struct {
	Name       string `json:"name"`
	NameNative string `json:"name_native"`
}

// OrtusBearing is the bearing to the most salient nearby place.
type OrtusBearing struct {
	Label      string  `json:"label"`
	Reference  string  `json:"reference"`
	Compass    string  `json:"compass"`
	DistanceKm float64 `json:"distance_km"`
	Inside     bool    `json:"inside"`
}

// OrtusExposure is the terrain exposure (slope and aspect).
type OrtusExposure struct {
	SlopeDeg      float64  `json:"slope_deg"`
	AspectDeg     *float64 `json:"aspect_deg"`
	AspectCompass string   `json:"aspect_compass"`
	Flat          bool     `json:"flat"`
}

// OrtusElevation is the height above sea level at the point.
type OrtusElevation struct {
	Meters    float64 `json:"meters"`
	AccuracyM float64 `json:"accuracy_m"`
	SeaLevel  bool    `json:"sea_level"`
}

// Ortus wraps the Ortus point-query geo service. BaseURL is
// configurable so tests can point at a local fake. Logger is optional.
type Ortus struct {
	BaseURL    string
	HTTPClient *http.Client
	Cache      *Geocache
	MaxRetries int
	Logger     *slog.Logger
}

const ortusService = "ortus"

func (o *Ortus) log() *slog.Logger {
	if o.Logger != nil {
		return o.Logger
	}
	return slog.Default()
}

// Query returns Ortus' answer for (lat, lon). It consults the cache
// first; on miss it calls the service with retry and writes through.
func (o *Ortus) Query(ctx context.Context, lat, lon float64) (*OrtusResponse, error) {
	start := time.Now()
	key := CoordinateKey(lat, lon, "")

	if o.Cache != nil {
		raw, err := o.Cache.Get(ortusService, key)
		switch {
		case err == nil:
			var resp OrtusResponse
			if json.Unmarshal(raw, &resp) == nil {
				o.log().Debug("ortus: query",
					slog.String("service", ortusService),
					slog.String("cache", "hit"),
					slog.Int64("duration_ms", time.Since(start).Milliseconds()),
				)
				return &resp, nil
			}
		case !errors.Is(err, sql.ErrNoRows):
			return nil, fmt.Errorf("cache read: %w", err)
		}
	}

	body, err := o.fetch(ctx, lat, lon)
	if err != nil {
		attrs := []any{
			slog.String("service", ortusService),
			slog.String("cache", "miss"),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
		}
		var se *HTTPStatusError
		if errors.As(err, &se) {
			attrs = append(attrs, slog.Int("status", se.StatusCode))
		}
		attrs = append(attrs, slog.Any("err", err))
		o.log().Warn("ortus: query failed", attrs...)
		return nil, err
	}

	var resp OrtusResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("decode ortus response: %w", err)
	}

	if o.Cache != nil {
		// The answer is valid; a failing cache only costs a re-query.
		if err := o.Cache.Put(ortusService, key, body); err != nil {
			o.log().Warn("ortus: cache write failed",
				slog.String("service", ortusService),
				slog.Any("err", err),
			)
		}
	}
	o.log().Info("ortus: query",
		slog.String("service", ortusService),
		slog.String("cache", "miss"),
		slog.Int64("duration_ms", time.Since(start).Milliseconds()),
	)
	return &resp, nil
}

func (o *Ortus) fetch(ctx context.Context, lat, lon float64) ([]byte, error) {
	q := url.Values{}
	q.Set("lon", strconv.FormatFloat(lon, 'f', 6, 64))
	q.Set("lat", strconv.FormatFloat(lat, 'f', 6, 64))
	full := strings.TrimRight(o.BaseURL, "/") + "/api/v1/query?" + q.Encode()
	return doWithRetry(ctx, o.HTTPClient, http.MethodGet, full, nil, o.MaxRetries)
}
