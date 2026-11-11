// Phase Z — Zeitzone, Sample-ID, Höhe.
//
//   - samples: time_zone → timezone (rename keeps the data),
//     timezone_source (select, backfill 'device'), collecting_day
//     (text YYYY-MM-DD, backfill from fieldtrips), elevation_dem and
//     elevation_dem_accuracy are removed after their values were moved
//     into elevation / vertical_accuracy (only where no elevation
//     source was set yet).
//   - fieldtrips: timezone (text, backfill 'Europe/Berlin').
//   - users: sample_id_format, sample_id_prefix, sample_id_offset.
//     day_cutoff_hour stays untouched.
//   - Existing duplicate (owner, sample_id) pairs get a " (n)" suffix,
//     the later-created record keeps the sent ID in original_code.
//     No DB-level UNIQUE index: the PocketBase form validator would
//     reject collisions before the hook can suffix them.
package migrations

import (
	"fmt"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func phaseZSuffixDuplicates(db dbx.Builder) error {
	type row struct {
		ID       string `db:"id"`
		Owner    string `db:"owner"`
		SampleID string `db:"sample_id"`
	}
	var rows []row
	if err := db.NewQuery(`SELECT id, owner, sample_id FROM samples
		WHERE sample_id IS NOT NULL AND sample_id != ''
		ORDER BY owner, sample_id, created, id`).All(&rows); err != nil {
		return err
	}
	taken := map[string]bool{}
	for _, r := range rows {
		taken[r.Owner+"\x00"+r.SampleID] = true
	}
	seen := map[string]int{}
	for _, r := range rows {
		key := r.Owner + "\x00" + r.SampleID
		seen[key]++
		if seen[key] == 1 {
			continue
		}
		n := seen[key]
		var candidate string
		for {
			candidate = fmt.Sprintf("%s (%d)", r.SampleID, n)
			if !taken[r.Owner+"\x00"+candidate] {
				break
			}
			n++
		}
		taken[r.Owner+"\x00"+candidate] = true
		if _, err := db.NewQuery(`UPDATE samples SET sample_id={:sid}, original_code={:orig} WHERE id={:id}`).
			Bind(dbx.Params{"sid": candidate, "orig": r.SampleID, "id": r.ID}).Execute(); err != nil {
			return err
		}
	}
	return nil
}

func phaseZUp(app core.App) error {
	db := app.DB()

	// 1. Duplicates first, while sample_id is still untouched.
	if err := phaseZSuffixDuplicates(db); err != nil {
		return err
	}

	// 2. samples: rename + new columns (DEM columns stay until moved).
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	renameField(samples, "time_zone", "timezone")
	addFieldIfMissing(samples, &core.SelectField{
		Name:      "timezone_source",
		Values:    []string{"device", "location_service", "manual"},
		MaxSelect: 1,
	})
	addFieldIfMissing(samples, &core.TextField{Name: "collecting_day"})
	if err := app.Save(samples); err != nil {
		return err
	}

	// 3. fieldtrips + users.
	fieldtrips, err := app.FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		return err
	}
	if fieldtrips.Fields.GetByName("timezone") == nil {
		fieldtrips.Fields.Add(&core.TextField{Name: "timezone"})
		if err := app.Save(fieldtrips); err != nil {
			return err
		}
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	changed := false
	for _, f := range []core.Field{
		&core.TextField{Name: "sample_id_format"},
		&core.TextField{Name: "sample_id_prefix"},
		&core.NumberField{Name: "sample_id_offset"},
	} {
		if users.Fields.GetByName(f.GetName()) == nil {
			users.Fields.Add(f)
			changed = true
		}
	}
	if changed {
		if err := app.Save(users); err != nil {
			return err
		}
	}

	// 4. Backfills; DEM values move before their columns are dropped.
	for _, q := range []string{
		`UPDATE samples SET timezone = 'Europe/Berlin' WHERE timezone IS NULL OR timezone = ''`,
		`UPDATE samples SET timezone_source = 'device' WHERE timezone_source IS NULL OR timezone_source = ''`,
		`UPDATE samples SET collecting_day = COALESCE(
			(SELECT f.collecting_day FROM fieldtrips f WHERE f.id = samples.fieldtrip), '')
		 WHERE collecting_day IS NULL OR collecting_day = ''`,
		`UPDATE fieldtrips SET timezone = 'Europe/Berlin' WHERE timezone IS NULL OR timezone = ''`,
		`UPDATE samples SET elevation = elevation_dem,
			vertical_accuracy = elevation_dem_accuracy,
			elevation_source = 'backend_service'
		 WHERE (elevation_source IS NULL OR elevation_source = '')
		   AND (elevation IS NULL OR elevation = 0)
		   AND elevation_dem IS NOT NULL AND elevation_dem != 0`,
	} {
		if _, err := db.NewQuery(q).Execute(); err != nil {
			return err
		}
	}

	// 5. Drop the DEM columns.
	samples, err = app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	removeFields(samples, "elevation_dem", "elevation_dem_accuracy")
	return app.Save(samples)
}

func phaseZDown(app core.App) error {
	samples, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	removeFields(samples, "timezone_source", "collecting_day")
	renameField(samples, "timezone", "time_zone")
	for _, n := range []string{"elevation_dem", "elevation_dem_accuracy"} {
		addFieldIfMissing(samples, &core.NumberField{Name: n})
	}
	if err := app.Save(samples); err != nil {
		return err
	}
	fieldtrips, err := app.FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		return err
	}
	if fieldtrips.Fields.GetByName("timezone") != nil {
		removeFields(fieldtrips, "timezone")
		if err := app.Save(fieldtrips); err != nil {
			return err
		}
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	removeFields(users, "sample_id_format", "sample_id_prefix", "sample_id_offset")
	return app.Save(users)
}

func init() {
	m.Register(phaseZUp, phaseZDown)
}
