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

// recomputeExcursionDerived loads all samples for the given excursion,
// updates the centroid, and recomputes the astro snapshot. Best-effort
// — never crashes the enclosing goroutine, just logs and moves on.
func (e *Enricher) recomputeExcursionDerived(excID string) {
	dao := e.App.Dao()
	exc, err := dao.FindRecordById("excursions", excID)
	if err != nil {
		e.log().Warn("astro: excursion vanished", slog.String("id", excID), slog.Any("err", err))
		return
	}

	samples, err := dao.FindRecordsByFilter("samples", "excursion = {:exc}", "", 0, 0,
		map[string]any{"exc": excID})
	if err != nil {
		e.log().Warn("astro: sample query failed", slog.String("id", excID), slog.Any("err", err))
		return
	}
	if len(samples) == 0 {
		return
	}

	cLat, cLon := centroid(samples)
	exc.Set("centroid_lat", cLat)
	exc.Set("centroid_lon", cLon)

	day := parseCollectingDay(exc.GetString("collecting_day"), berlinTZ())
	startedAt := exc.GetDateTime("started_at").Time()
	endedAt := exc.GetDateTime("ended_at").Time()

	a := astro.ComputeExcursionAstro(day, startedAt, endedAt, cLat, cLon)
	raw, err := json.Marshal(a)
	if err != nil {
		e.log().Warn("astro: marshal failed", slog.Any("err", err))
		return
	}
	exc.Set("astro", string(raw))

	// Phase-5 denormalised columns for fast filtering. day_of_year
	// always reflects collecting_day; country / admin_area mirror
	// whatever admin_units currently has (may be empty if the
	// labelloc enrichment hasn't landed yet — they get filled the
	// next time this hook runs).
	exc.Set("day_of_year", day.YearDay())
	if au := decodeAdminUnits(exc.GetString("admin_units")); au != nil {
		exc.Set("country", au.Country)
		exc.Set("admin_area", au.AdminArea)
	}

	// Locality suggestion: only when the user hasn't already chosen
	// one. We never overwrite a manual assignment. Suggestions are
	// scoped to the excursion's owner — user A must not see user B's
	// localities in the prompt.
	if exc.GetString("locality") == "" {
		ownerID := exc.GetString("owner")
		if suggested := nearestLocalityID(dao, ownerID, cLat, cLon); suggested != "" {
			exc.Set("suggested_locality", suggested)
		} else {
			// Drop a stale suggestion that no longer applies (e.g.
			// centroid moved out of the radius).
			exc.Set("suggested_locality", "")
		}
	}

	if err := dao.SaveRecord(exc); err != nil {
		e.log().Warn(
			"astro: save failed",
			slog.String("id", excID),
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
			Lat:     r.GetFloat("centroid_lat"),
			Lon:     r.GetFloat("centroid_lon"),
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
		lat += s.GetFloat("lat")
		lon += s.GetFloat("lon")
	}
	n := float64(len(samples))
	return lat / n, lon / n
}

// decodeAdminUnits parses the JSON we stored on the excursion (which
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
