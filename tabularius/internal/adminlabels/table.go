// Package adminlabels maps (country ISO, OSM admin level) to a flat
// admin_* column and a country-specific term. The canonical JSON lives in
// shared/admin-labels/ and is copied here via scripts/sync-admin-labels.sh.
package adminlabels

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

// Tier is the name of a flat admin column.
type Tier string

// Tiers lists all storable admin columns, coarse to fine.
var Tiers = []Tier{
	"admin_country", "admin_state", "admin_region", "admin_province",
	"admin_county", "admin_district", "admin_municipality", "admin_borough",
	"admin_parish", "admin_submunicipality", "admin_other",
}

// LevelEntry describes one admin level of a country. A nil Column means the
// level is known but not stored (another level of the same country owns the tier).
type LevelEntry struct {
	Column *Tier  `json:"column"`
	Term   string `json:"term"`
}

// Country holds the level table of one country.
type Country struct {
	Name     string             `json:"name"`
	Reviewed bool               `json:"reviewed"`
	Levels   map[int]LevelEntry `json:"levels"`
}

// Table is the full label table.
type Table struct {
	Version   int                `json:"version"`
	Countries map[string]Country `json:"countries"`
}

//go:embed admin_labels.json
var embedded []byte

// Default returns the embedded table. It panics only if the embedded file is broken.
func Default() *Table {
	var t Table
	if err := json.Unmarshal(embedded, &t); err != nil {
		panic(fmt.Sprintf("adminlabels: invalid embedded admin_labels.json: %v", err))
	}
	return &t
}

// Column returns the column for (iso, level). ok=false means the pair is
// unknown; ok=true with an empty Tier means known but not stored.
func (t *Table) Column(iso string, level int) (Tier, bool) {
	e, ok := t.entry(iso, level)
	if !ok {
		return "", false
	}
	if e.Column == nil {
		return "", true
	}
	return *e.Column, true
}

// Term returns the country-specific term, or "" if unknown.
func (t *Table) Term(iso string, level int) string {
	e, _ := t.entry(iso, level)
	return e.Term
}

func (t *Table) entry(iso string, level int) (LevelEntry, bool) {
	c, ok := t.Countries[iso]
	if !ok {
		return LevelEntry{}, false
	}
	e, ok := c.Levels[level]
	return e, ok
}
