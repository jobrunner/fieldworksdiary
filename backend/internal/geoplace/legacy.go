package geoplace

import (
	"fmt"
	"log/slog"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

// LegacyPlacemarkFields are the pre-Ortus placemark text columns that
// MapLegacyManualPlacemarks reads. Migration 1700000027 drops them right
// after the mapping ran.
var LegacyPlacemarkFields = []string{
	"country", "administrative_area", "sub_administrative_area", "locality",
	"sub_locality", "postal_code", "name", "thoroughfare",
}

// legacyTiers maps the legacy admin text columns onto the new tiers.
// postal_code, name and thoroughfare have no new column; their old values
// only go to the log so nothing user-curated disappears silently.
var legacyTiers = map[string]adminlabels.Tier{
	"administrative_area":     "admin_state",
	"sub_administrative_area": "admin_county",
	"locality":                "admin_municipality",
	"sub_locality":            "admin_submunicipality",
}

// MapLegacyManualPlacemarks moves the legacy text columns of manual
// placemarks that have no country_iso yet onto the flat columns
// (country → country_iso, administrative_area → admin_state, …), fills the
// owner from the oldest referencing locality/sample, gives every further
// referencing owner its own manual clone (pre-O rows were shared; the
// view rule hides other owners' manual rows) and repoints that owner's
// samples and localities to it. Source stays manual. One Info line per
// placemark carries old and new values.
//
// Pure DB work, safe inside a migration transaction. When the legacy
// columns are already gone it does nothing. It returns the number of
// mapped placemarks.
func MapLegacyManualPlacemarks(dao *daos.Dao, logger *slog.Logger) (int, error) {
	if logger == nil {
		logger = slog.Default()
	}
	pmColl, err := dao.FindCollectionByNameOrId("placemarks")
	if err != nil {
		return 0, err
	}
	for _, f := range LegacyPlacemarkFields {
		if pmColl.Schema.GetFieldByName(f) == nil {
			logger.Info("legacy placemarks: skipped, legacy columns are gone",
				slog.String("missing_column", f))
			return 0, nil
		}
	}
	filter := "geocoding_source = 'manual' && country_iso = '' && ("
	for i, f := range LegacyPlacemarkFields {
		if i > 0 {
			filter += " || "
		}
		filter += f + " != ''"
	}
	filter += ")"
	pms, err := dao.FindRecordsByFilter("placemarks", filter, "created", 0, 0)
	if err != nil {
		return 0, err
	}
	done := 0
	for _, pm := range pms {
		old := map[string]string{}
		for _, f := range LegacyPlacemarkFields {
			old[f] = pm.GetString(f)
		}
		p := Place{CountryISO: old["country"], Admin: map[adminlabels.Tier]AdminValue{}}
		for legacy, tier := range legacyTiers {
			if old[legacy] != "" {
				p.Admin[tier] = AdminValue{Name: old[legacy]}
			}
		}
		owners := referencingOwners(dao, pm.Id)
		owner := pm.GetString("owner")
		if owner == "" && len(owners) > 0 {
			owner = owners[0]
		}
		ApplyPlace(pm, p)
		pm.Set("dedup_hash", p.DedupHash())
		if owner != "" {
			pm.Set("owner", owner)
		}
		if err := dao.SaveRecord(pm); err != nil {
			return done, fmt.Errorf("save placemark %s: %w", pm.Id, err)
		}
		for _, o := range owners {
			if o == owner {
				continue
			}
			clone, err := LookupOrCreatePlacemark(dao, p, "manual", o)
			if err != nil {
				return done, fmt.Errorf("clone placemark %s: %w", pm.Id, err)
			}
			err = dao.RunInTransaction(func(tx *daos.Dao) error {
				for _, field := range []string{"placemark", "placemark_suggestion"} {
					if _, err := Repoint(tx, "samples", field, pm.Id, clone.Id, o); err != nil {
						return err
					}
				}
				_, err := Repoint(tx, "localities", "placemark", pm.Id, clone.Id, o)
				return err
			})
			if err != nil {
				return done, fmt.Errorf("repoint owner clone %s: %w", pm.Id, err)
			}
			logger.Info("legacy placemarks: owner clone",
				slog.String("placemark_id", pm.Id),
				slog.String("clone_id", clone.Id),
				slog.String("user_id", o))
		}
		done++
		logger.Info("legacy placemarks: manual placemark mapped",
			slog.String("placemark_id", pm.Id),
			slog.String("user_id", owner),
			slog.String("old_country", old["country"]),
			slog.String("old_administrative_area", old["administrative_area"]),
			slog.String("old_sub_administrative_area", old["sub_administrative_area"]),
			slog.String("old_locality", old["locality"]),
			slog.String("old_sub_locality", old["sub_locality"]),
			slog.String("old_postal_code", old["postal_code"]),
			slog.String("old_name", old["name"]),
			slog.String("old_thoroughfare", old["thoroughfare"]),
			slog.String("new_country_iso", p.CountryISO),
			slog.String("new_admin_state", p.Admin["admin_state"].Name),
			slog.String("new_admin_county", p.Admin["admin_county"].Name),
			slog.String("new_admin_municipality", p.Admin["admin_municipality"].Name),
			slog.String("new_admin_submunicipality", p.Admin["admin_submunicipality"].Name),
		)
	}
	logger.Info("legacy placemarks: done", slog.Int("count", done))
	return done, nil
}

// referencingOwners lists the distinct owners of localities and samples
// that reference the placemark, oldest reference first.
func referencingOwners(dao *daos.Dao, placemarkID string) []string {
	var out []string
	seen := map[string]bool{}
	for _, coll := range []string{"localities", "samples"} {
		filter := "placemark = {:p}"
		if coll == "samples" {
			filter += " || placemark_suggestion = {:p}"
		}
		recs, err := dao.FindRecordsByFilter(coll, filter, "created", 0, 0, dbx.Params{"p": placemarkID})
		if err != nil {
			continue
		}
		for _, rec := range recs {
			if o := rec.GetString("owner"); o != "" && !seen[o] {
				seen[o] = true
				out = append(out, o)
			}
		}
	}
	return out
}

// Repoint sets field=to on every record of coll whose field is from
// (restricted to one owner when owner != ""), bumping the version so
// clients holding the old one get a 409. It returns the number of
// records changed.
func Repoint(tx *daos.Dao, coll, field, from, to, owner string) (int, error) {
	filter := field + " = {:f}"
	params := dbx.Params{"f": from}
	if owner != "" {
		filter += " && owner = {:o}"
		params["o"] = owner
	}
	recs, err := tx.FindRecordsByFilter(coll, filter, "", 0, 0, params)
	if err != nil {
		return 0, err
	}
	for _, rec := range recs {
		rec.Set(field, to)
		rec.Set("version", rec.GetInt("version")+1)
		if err := tx.SaveRecord(rec); err != nil {
			return 0, err
		}
	}
	return len(recs), nil
}
