package geoplace

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"go.mett.io/fwd-backend/internal/mtb"
	"go.mett.io/fwd-backend/internal/services"
)

const tk25Source = "tk25-blattschnitt-de"

// FromOrtus maps an Ortus response for (lat, lon) onto place columns, geo
// values and features.
func FromOrtus(r *services.OrtusResponse, lat, lon float64, t *adminlabels.Table) Result {
	var res Result
	if r == nil {
		return res
	}
	if g := r.Gazetteer; g != nil {
		if g.Admin != nil {
			res.Place = mapPlace(g, t)
		}
		mapGeo(g, &res.Geo)
	}
	res.Features = mapFeatures(r.Results)
	if res.Place != nil && res.Place.CountryISO == "DE" {
		mapMTB(r.Results, lat, lon, &res.Geo)
	}
	return res
}

func mapPlace(g *services.OrtusGazetteer, t *adminlabels.Table) *Place {
	iso := g.Admin.CountryISO
	p := &Place{CountryISO: iso, Admin: map[adminlabels.Tier]AdminValue{}}
	for _, u := range g.Admin.Hierarchy {
		col, known := t.Column(iso, u.Level)
		switch {
		case known && col == "":
			continue
		case !known:
			col = adminlabels.Tier("admin_" + u.Equivalent)
			if !validTier(col) {
				col = "admin_other"
			}
		}
		if cur, taken := p.Admin[col]; taken && (!known || cur.Level <= u.Level) {
			// fallback never overwrites; among known units the lower level wins
			continue
		}
		p.Admin[col] = AdminValue{Name: u.Name, Native: u.NameNative, Level: u.Level}
	}
	if len(g.Islands) > 0 {
		p.Island = g.Islands[0].Name
	}
	if m := g.Mountains; m != nil {
		if m.Mountain != nil {
			p.Mountain = m.Mountain.Name
		}
		if m.Range != nil {
			p.MountainRange = m.Range.Name
		}
	}
	return p
}

func validTier(c adminlabels.Tier) bool {
	for _, t := range adminlabels.Tiers {
		if t == c {
			return true
		}
	}
	return false
}

func mapGeo(g *services.OrtusGazetteer, out *SampleGeo) {
	if e := g.Elevation; e != nil {
		m := e.Meters
		if e.SeaLevel {
			m = 0
		}
		acc := e.AccuracyM
		out.ElevationDEM, out.ElevationDEMAccuracy = &m, &acc
	}
	if x := g.Exposure; x != nil {
		slope := x.SlopeDeg
		out.SlopeDeg = &slope
		out.AspectDeg = x.AspectDeg
		out.AspectCompass = x.AspectCompass
		out.TerrainFlat = x.Flat
	}
	if b := g.Bearing; b != nil {
		d := b.DistanceKm
		out.BearingLabel, out.BearingReference, out.BearingCompass = b.Label, b.Reference, b.Compass
		out.BearingDistanceKm, out.BearingInside = &d, b.Inside
	}
}

func mapFeatures(results []services.OrtusSourceResult) []Feature {
	var fs []Feature
	for _, sr := range results {
		for _, f := range sr.Features {
			fs = append(fs, Feature{
				SourceID: sr.SourceID, SourceName: sr.SourceName, Layer: f.Layer,
				FeatureID: rawIDString(f.ID), Properties: f.Properties, License: sr.License,
			})
		}
	}
	return fs
}

func rawIDString(raw json.RawMessage) string {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	if raw[0] == '"' {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			return s
		}
	}
	return string(raw)
}

// sheetNumber liest die Blattnummer aus den Feature-Properties (id, sonst
// dtknummer). Die Feature-ID von Ortus ist nur ein Zeilenindex.
func sheetNumber(props map[string]any) string {
	for _, key := range []string{"id", "dtknummer"} {
		switch v := props[key].(type) {
		case string:
			if s := strings.TrimSpace(v); s != "" {
				return s
			}
		case float64:
			return strconv.FormatFloat(v, 'f', -1, 64)
		case json.Number:
			if s := v.String(); s != "" {
				return s
			}
		}
	}
	return ""
}

func mapMTB(results []services.OrtusSourceResult, lat, lon float64, out *SampleGeo) {
	for _, sr := range results {
		if sr.SourceID != tk25Source || len(sr.Features) == 0 {
			continue
		}
		f := sr.Features[0]
		out.MTBSheetNumber = sheetNumber(f.Properties)
		if name, ok := f.Properties["blattname"].(string); ok {
			out.MTBSheetName = strings.TrimSpace(name)
		}
		if _, _, q, ok := mtb.Cell(lat, lon); ok {
			out.MTBQuadrant = q
		}
		return
	}
}
