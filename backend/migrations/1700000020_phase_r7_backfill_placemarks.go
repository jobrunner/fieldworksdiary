// Phase R7.3 — backfill placemarks from the legacy
// `samples.admin_units` JSON snapshots.
//
// Pre-R3 every reverse-geocoding result lived only as a JSON blob
// on the originating sample (and, propagated, on the parent
// fieldtrip). R3 added the `placemarks` collection + a single-
// relation on Locality; R7.1 wired the auto-geocode hook that fills
// the relation on every new locality. The historical data, though,
// still sits on `samples.admin_units` — and the matching Localities
// don't have a `placemark` attached yet.
//
// This migration walks the existing samples once, lifts each
// `admin_units` snapshot into a Placemark row (deduplicated via the
// same hash the R7.1 hook uses), and where a Sample already points
// at a Locality, attaches the Placemark to that Locality.
//
// Idempotent: re-running is a no-op because lookup-or-create skips
// duplicates and the locality-attach guard skips already-attached
// rows.
//
// Note: the `samples.admin_units` column itself stays in place.
// Dropping it (R7.4) is a follow-up step that needs Staging
// observation first — Spec §6.1.
package migrations

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models"
	"golang.org/x/text/unicode/norm"
)

// adminUnitsSnapshot mirrors the labelloc result shape we used to
// store on the sample. The field tags follow the legacy JSON, not
// the new placemarks schema.
type adminUnitsSnapshot struct {
	Country    string `json:"country"`
	CountryISO string `json:"countryIso"`
	AdminArea  string `json:"adminArea"`
	AdminArea2 string `json:"adminArea2"`
	Locality   string `json:"locality"`
}

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)
		samples, err := dao.FindRecordsByFilter(
			"samples",
			"admin_units != ''",
			"", 0, 0,
		)
		if err != nil {
			return err
		}
		for _, s := range samples {
			if err := backfillOnePlacemark(dao, s); err != nil {
				// Keep going on per-row failures — a single bad
				// snapshot must not block the whole backfill.
				continue
			}
		}
		return nil
	}, func(db dbx.Builder) error {
		// Down: no-op. We don't reverse a data migration; if
		// somebody really wants to undo this, they delete the
		// placemarks collection (which the R3 migration's down
		// does already).
		return nil
	})
}

func backfillOnePlacemark(dao *daos.Dao, sample *models.Record) error {
	raw := sample.GetString("admin_units")
	if raw == "" {
		return nil
	}
	var snap adminUnitsSnapshot
	if err := json.Unmarshal([]byte(raw), &snap); err != nil {
		return nil // malformed snapshot — silently skip
	}
	country := strings.ToUpper(strings.TrimSpace(snap.CountryISO))
	if country == "" {
		return nil // no ISO-2 code; can't synthesize a placemark
	}
	hash := backfillDedupHash(country, snap.AdminArea, snap.Locality, "")

	pm, err := backfillLookupOrCreate(dao, hash, country, snap.AdminArea, snap.AdminArea2, snap.Locality)
	if err != nil {
		return err
	}

	// Optionally attach the placemark to the Sample's Locality, but
	// only when the relation is set and still empty. Bestands-Samples
	// pre-R10 won't have `locality` set; that's fine, the placemark
	// row still landed in the table so the R7.1 hook can find it
	// later.
	localityID := sample.GetString("locality")
	if localityID == "" {
		return nil
	}
	loc, err := dao.FindRecordById("localities", localityID)
	if err != nil {
		return nil // locality vanished
	}
	if loc.GetString("placemark") != "" {
		return nil // already attached, leave it
	}
	loc.Set("placemark", pm.Id)
	return dao.SaveRecord(loc)
}

func backfillLookupOrCreate(dao *daos.Dao, hash, country, adminArea, subAdminArea, locality string) (*models.Record, error) {
	existing, err := dao.FindFirstRecordByFilter(
		"placemarks",
		"dedup_hash = {:h}",
		dbx.Params{"h": hash},
	)
	if err == nil && existing != nil {
		return existing, nil
	}
	coll, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return nil, err
	}
	rec := models.NewRecord(coll)
	rec.Set("country", country)
	rec.Set("administrative_area", adminArea)
	rec.Set("sub_administrative_area", subAdminArea)
	rec.Set("locality", locality)
	rec.Set("geocoding_source", "backend-service")
	rec.Set("dedup_hash", hash)
	if err := dao.SaveRecord(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// backfillDedupHash mirrors the (since removed) enrichment dedup hash and
// `api.manualDedupHash`. We keep a third copy here because the
// `migrations` package is the bootstrap layer — pulling in
// `internal/enrichment` would create an import cycle through the
// PocketBase dao that the migration package wraps. The
// algorithm-locked-constant tests in both other packages cover
// drift on this side too: any future hash change has to be applied
// to all three copies, and the test fixtures pin the canonical
// digest down.
func backfillDedupHash(country, administrativeArea, locality, postalCode string) string {
	parts := []string{
		backfillNormalize(country),
		backfillNormalize(administrativeArea),
		backfillNormalize(locality),
		backfillNormalize(postalCode),
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:])
}

func backfillNormalize(s string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(s)))
}
