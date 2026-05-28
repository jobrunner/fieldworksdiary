// Phase R7.1 — backend-driven reverse geocoding for localities.
//
// Spec §6 architecture: clients never call CLGeocoder or its
// equivalents; reverse-geocoding happens server-side against the
// existing `labelloc` service, the parsed result lands as a row in
// the deduplicated `placemarks` collection, and the originating
// locality holds a single-relation `placemark` pointer.
//
// This file wires the hook + lookup-or-create dance + the
// dedup-hash function. The actual HTTP call sits in
// `internal/services/labelloc.go`; its 7-day geocache survives
// re-runs across server restarts.
package enrichment

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"log/slog"
	"runtime/debug"
	"strings"
	"time"

	"go.mett.io/fwd-backend/internal/fusion"
	"go.mett.io/fwd-backend/internal/services"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
	"golang.org/x/text/unicode/norm"
)

// PlacemarkEnricher reverse-geocodes a locality's coordinate and
// attaches the resulting Placemark. Construct one at startup, hand
// it to `RegisterPlacemarkEnricher`.
type PlacemarkEnricher struct {
	App      core.App
	Labelloc *services.Labelloc
	Timeout  time.Duration
	Logger   *slog.Logger
}

// RegisterPlacemarkEnricher wires the create + update hooks on the
// localities collection. The handler runs in a goroutine with a
// recover guard so a labelloc outage never blocks the originating
// save.
func RegisterPlacemarkEnricher(app *pocketbase.PocketBase, e *PlacemarkEnricher) {
	e.App = app

	app.OnRecordAfterCreateRequest("localities").Add(func(ev *core.RecordCreateEvent) error {
		id := ev.Record.Id
		go e.runSafely(id)
		return nil
	})

	app.OnRecordAfterUpdateRequest("localities").Add(func(ev *core.RecordUpdateEvent) error {
		original := ev.Record.OriginalCopy()
		prevLat := original.GetFloat("latitude")
		prevLon := original.GetFloat("longitude")
		newLat := ev.Record.GetFloat("latitude")
		newLon := ev.Record.GetFloat("longitude")
		// Re-fire if the coordinate moved meaningfully OR if we
		// still have no placemark attached. The second clause
		// catches the case where a labelloc outage left a freshly
		// created locality without a result.
		if !fusion.SignificantCoordChange(prevLat, prevLon, newLat, newLon) &&
			ev.Record.GetString("placemark") != "" {
			return nil
		}
		id := ev.Record.Id
		go e.runSafely(id)
		return nil
	})
}

func (e *PlacemarkEnricher) log() *slog.Logger {
	if e.Logger != nil {
		return e.Logger
	}
	return e.App.Logger()
}

func (e *PlacemarkEnricher) timeout() time.Duration {
	if e.Timeout > 0 {
		return e.Timeout
	}
	return 15 * time.Second
}

func (e *PlacemarkEnricher) runSafely(localityID string) {
	defer func() {
		if r := recover(); r != nil {
			e.log().Error(
				"placemark panic",
				slog.String("locality_id", localityID),
				slog.Any("recover", r),
				slog.String("stack", string(debug.Stack())),
			)
		}
	}()
	if err := e.run(localityID); err != nil {
		e.log().Warn(
			"placemark enrich failed",
			slog.String("locality_id", localityID),
			slog.Any("err", err),
		)
	}
}

// run is the actual work, exported (lowercase but called from tests
// in the same package) so the test can drive it synchronously and
// assert on the post-state.
func (e *PlacemarkEnricher) run(localityID string) error {
	dao := e.App.Dao()
	loc, err := dao.FindRecordById("localities", localityID)
	if err != nil {
		// Locality may have been merged away by the fusion hook
		// running in parallel — that's a benign race, not an
		// error.
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}

	// Manual overrides are sacrosanct (Spec §6.1): if the user
	// hand-edited the placemark, the auto-geocoder must not
	// stomp it.
	if pmID := loc.GetString("placemark"); pmID != "" {
		if pm, err := dao.FindRecordById("placemarks", pmID); err == nil {
			if pm.GetString("geocoding_source") == "manual" {
				return nil
			}
		}
	}

	lat := loc.GetFloat("latitude")
	lon := loc.GetFloat("longitude")
	if lat == 0 && lon == 0 {
		// No coordinate yet — nothing to geocode.
		return nil
	}

	if e.Labelloc == nil {
		// Test / dev mode without a labelloc client wired in.
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), e.timeout())
	defer cancel()

	result, err := e.Labelloc.Lookup(ctx, lat, lon, "de")
	if err != nil {
		// Labelloc outages are recoverable: the next coordinate
		// update will re-fire the hook, and the geocache keeps a
		// successful response for a week. We deliberately do not
		// queue a retry here — that belongs in a future "retry
		// queue" if labelloc proves flaky enough to matter.
		return err
	}
	country := strings.TrimSpace(result.CountryISO)
	if country == "" {
		// Labelloc returned a row without an ISO-2 country —
		// outside its known coverage (e.g. an exotic ocean
		// point). Can't synthesize a placemark; leave the locality
		// alone.
		return nil
	}

	hash := PlacemarkDedupHash(
		country,
		result.AdminArea,
		result.Locality,
		"", // postal code — labelloc doesn't expose it today
	)

	pmRec, err := lookupOrCreatePlacemark(dao, hash, placemarkFields{
		country:               country,
		administrativeArea:    result.AdminArea,
		subAdministrativeArea: result.AdminArea2,
		locality:              result.Locality,
	})
	if err != nil {
		return err
	}

	if loc.GetString("placemark") == pmRec.Id {
		// Already attached to this exact placemark — nothing to
		// save. Spares an unnecessary version bump.
		return nil
	}
	loc.Set("placemark", pmRec.Id)
	return dao.SaveRecord(loc)
}

// placemarkFields is the small bag of strings the lookup-or-create
// needs. Pulled out so the function signature stays short.
type placemarkFields struct {
	country               string
	administrativeArea    string
	subAdministrativeArea string
	locality              string
}

func lookupOrCreatePlacemark(dao *daos.Dao, hash string, f placemarkFields) (*models.Record, error) {
	existing, err := dao.FindFirstRecordByFilter(
		"placemarks",
		"dedup_hash = {:h}",
		dbx.Params{"h": hash},
	)
	if err == nil && existing != nil {
		return existing, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	coll, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return nil, err
	}
	rec := models.NewRecord(coll)
	rec.Set("country", f.country)
	rec.Set("administrative_area", f.administrativeArea)
	rec.Set("sub_administrative_area", f.subAdministrativeArea)
	rec.Set("locality", f.locality)
	rec.Set("geocoding_source", "backend-service")
	rec.Set("geocoding_date", time.Now())
	rec.Set("dedup_hash", hash)
	if err := dao.SaveRecord(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// PlacemarkDedupHash is the canonical Placemark identifier. Inputs
// are NFC-normalised, lowercased, trimmed, and `|`-joined; the
// resulting string is SHA-256-hashed to a fixed-width hex digest.
//
// Inputs in order:
//
//	country | administrative_area | locality | postal_code
//
// Why NFC: ISO-3166 country codes are ASCII but locality names like
// "Würzburg" come back from labelloc in different normal forms
// across runs (precomposed vs decomposed). Without NFC the same
// place produces different hashes on different machines.
//
// Spec §6.3 mandates this stays in the backend so client-side
// Unicode-library drift can't fork the hash space.
func PlacemarkDedupHash(country, administrativeArea, locality, postalCode string) string {
	parts := []string{
		normalizeForHash(country),
		normalizeForHash(administrativeArea),
		normalizeForHash(locality),
		normalizeForHash(postalCode),
	}
	joined := strings.Join(parts, "|")
	sum := sha256.Sum256([]byte(joined))
	return hex.EncodeToString(sum[:])
}

func normalizeForHash(s string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(s)))
}
