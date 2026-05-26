package enrichment

import (
	"encoding/json"
	"log/slog"
	"time"

	"go.mett.io/fwd-backend/internal/astro"
	"go.mett.io/fwd-backend/internal/grouping"
	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
)

// recomputeFieldtripDerived loads all samples for the given fieldtrip,
// updates the centroid, and recomputes the astro snapshot. Best-effort
// — never crashes the enclosing goroutine, just logs and moves on.
func (e *Enricher) recomputeFieldtripDerived(ftID string) {
	dao := e.App.Dao()
	ft, err := dao.FindRecordById("fieldtrips", ftID)
	if err != nil {
		e.log().Warn("astro: fieldtrip vanished", slog.String("id", ftID), slog.Any("err", err))
		return
	}

	samples, err := dao.FindRecordsByFilter("samples", "fieldtrip = {:ft}", "", 0, 0,
		map[string]any{"ft": ftID})
	if err != nil {
		e.log().Warn("astro: sample query failed", slog.String("id", ftID), slog.Any("err", err))
		return
	}
	if len(samples) == 0 {
		return
	}

	cLat, cLon := centroid(samples)
	ft.Set("centroid_lat", cLat)
	ft.Set("centroid_lon", cLon)

	day := parseCollectingDay(ft.GetString("collecting_day"), berlinTZ())
	startedAt := ft.GetDateTime("begin_date").Time()
	endedAt := ft.GetDateTime("end_date").Time()

	a := astro.ComputeFieldtripAstro(day, startedAt, endedAt, cLat, cLon)
	raw, err := json.Marshal(a)
	if err != nil {
		e.log().Warn("astro: marshal failed", slog.Any("err", err))
		return
	}
	ft.Set("astro", string(raw))

	// Phase-5 denormalised columns for fast filtering. day_of_year
	// always reflects collecting_day; country / admin_area mirror
	// whatever admin_units currently has (may be empty if the
	// labelloc enrichment hasn't landed yet — they get filled the
	// next time this hook runs).
	ft.Set("day_of_year", day.YearDay())
	if au := decodeAdminUnits(ft.GetString("admin_units")); au != nil {
		ft.Set("country", au.Country)
		ft.Set("admin_area", au.AdminArea)
	}

	// Locality suggestion: only when the user hasn't already chosen
	// one. We never overwrite a manual assignment. Suggestions are
	// scoped to the fieldtrip's owner — user A must not see user B's
	// localities in the prompt.
	if ft.GetString("locality") == "" {
		ownerID := ft.GetString("owner")
		if suggested := nearestLocalityID(dao, ownerID, cLat, cLon); suggested != "" {
			ft.Set("suggested_locality", suggested)
		} else {
			// Drop a stale suggestion that no longer applies (e.g.
			// centroid moved out of the radius).
			ft.Set("suggested_locality", "")
		}
	}

	if err := dao.SaveRecord(ft); err != nil {
		e.log().Warn(
			"astro: save failed",
			slog.String("id", ftID),
			slog.Any("err", err),
		)
	}
}

// nearestLocalityID loads localities owned by `ownerID` and picks the
// closest one whose centroid is within its own radius of (lat, lon).
// Returns "" if no locality qualifies (or if owner is empty, which
// would indicate a pre-Phase-11 record we shouldn't make suggestions
// for).
func nearestLocalityID(dao *daos.Dao, ownerID string, lat, lon float64) string {
	if ownerID == "" {
		return ""
	}
	recs, err := dao.FindRecordsByFilter(
		"localities",
		"owner = {:o}",
		"",
		500, 0,
		map[string]any{"o": ownerID},
	)
	if err != nil || len(recs) == 0 {
		return ""
	}
	candidates := make([]grouping.LocalityCandidate, 0, len(recs))
	for _, r := range recs {
		candidates = append(candidates, grouping.LocalityCandidate{
			ID:      r.Id,
			Name:    r.GetString("name"),
			Lat:     r.GetFloat("latitude"),
			Lon:     r.GetFloat("longitude"),
			RadiusM: r.GetFloat("radius_m"),
		})
	}
	if best := grouping.NearestLocalityWithin(lat, lon, candidates); best != nil {
		return best.ID
	}
	return ""
}

func centroid(samples []*models.Record) (lat, lon float64) {
	if len(samples) == 0 {
		return 0, 0
	}
	for _, s := range samples {
		lat += s.GetFloat("latitude")
		lon += s.GetFloat("longitude")
	}
	n := float64(len(samples))
	return lat / n, lon / n
}

// decodeAdminUnits parses the JSON we stored on the fieldtrip (which
// is the trimmed labelloc payload). Returns nil if the field is empty
// or malformed.
func decodeAdminUnits(raw string) *services.LabellocResult {
	if raw == "" {
		return nil
	}
	var v services.LabellocResult
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return nil
	}
	return &v
}

func parseCollectingDay(s string, loc *time.Location) time.Time {
	if t, err := time.ParseInLocation("2006-01-02", s, loc); err == nil {
		// Anchor at noon to avoid DST midnight ambiguity later.
		return time.Date(t.Year(), t.Month(), t.Day(), 12, 0, 0, 0, loc)
	}
	return time.Now().In(loc)
}

func berlinTZ() *time.Location {
	loc, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		return time.UTC
	}
	return loc
}
