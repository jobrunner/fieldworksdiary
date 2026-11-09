// Package geoplace maps an Ortus point-query response onto the flat place
// columns, per-sample geo values and features we store. The mapping is pure
// and has a Swift port that must produce identical results (shared test
// files in shared/testdata/ortus/), including the dedup hash.
package geoplace

import (
	"encoding/json"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

// AdminValue is one stored admin unit.
type AdminValue struct {
	Name, Native string
	Level        int
}

// Place is the shared (deduplicated) part of a location.
type Place struct {
	CountryISO    string
	Admin         map[adminlabels.Tier]AdminValue
	Island        string
	MountainRange string
	Mountain      string
}

// SampleGeo holds the per-sample geo values.
type SampleGeo struct {
	ElevationDEM, ElevationDEMAccuracy *float64
	SlopeDeg, AspectDeg                *float64
	AspectCompass                      string
	TerrainFlat                        bool

	BearingLabel, BearingReference, BearingCompass string
	BearingDistanceKm                              *float64
	BearingInside                                  bool

	MTBSheetNumber, MTBSheetName string
	MTBQuadrant                  int // 0 means none

	// Timezone is the IANA identifier at the point (Ortus source
	// timezones-2026a); empty means unknown.
	Timezone string
}

// Feature is one Ortus source feature at the query point.
type Feature struct {
	SourceID, SourceName, Layer, FeatureID string
	Properties                             map[string]any
	License                                json.RawMessage
}

// Result is the mapped Ortus response. Place is nil when Ortus has no
// admin coverage for the point (e.g. open sea).
type Result struct {
	Place    *Place
	Geo      SampleGeo
	Features []Feature
}
