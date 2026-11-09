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
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models/schema"
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

func phaseZUp(db dbx.Builder) error {
	dao := daos.New(db)

	// 1. Duplicates first, while sample_id is still untouched.
	if err := phaseZSuffixDuplicates(db); err != nil {
		return err
	}

	// 2. samples: rename + new columns (DEM columns stay until moved).
	samples, err := dao.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	if f := samples.Schema.GetFieldByName("time_zone"); f != nil {
		f.Name = "timezone"
	}
	if samples.Schema.GetFieldByName("timezone_source") == nil {
		samples.Schema.AddField(&schema.SchemaField{
			Name: "timezone_source", Type: schema.FieldTypeSelect,
			Options: &schema.SelectOptions{
				Values: []string{"device", "location_service", "manual"}, MaxSelect: 1,
			},
		})
	}
	if samples.Schema.GetFieldByName("collecting_day") == nil {
		samples.Schema.AddField(&schema.SchemaField{Name: "collecting_day", Type: schema.FieldTypeText})
	}
	if err := dao.SaveCollection(samples); err != nil {
		return err
	}

	// 3. fieldtrips + users.
	fieldtrips, err := dao.FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		return err
	}
	if fieldtrips.Schema.GetFieldByName("timezone") == nil {
		fieldtrips.Schema.AddField(&schema.SchemaField{Name: "timezone", Type: schema.FieldTypeText})
		if err := dao.SaveCollection(fieldtrips); err != nil {
			return err
		}
	}
	users, err := dao.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	changed := false
	for _, f := range []*schema.SchemaField{
		{Name: "sample_id_format", Type: schema.FieldTypeText},
		{Name: "sample_id_prefix", Type: schema.FieldTypeText},
		{Name: "sample_id_offset", Type: schema.FieldTypeNumber},
	} {
		if users.Schema.GetFieldByName(f.Name) == nil {
			users.Schema.AddField(f)
			changed = true
		}
	}
	if changed {
		if err := dao.SaveCollection(users); err != nil {
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
	samples, err = dao.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	for _, n := range []string{"elevation_dem", "elevation_dem_accuracy"} {
		if f := samples.Schema.GetFieldByName(n); f != nil {
			samples.Schema.RemoveField(f.Id)
		}
	}
	return dao.SaveCollection(samples)
}

func phaseZDown(db dbx.Builder) error {
	dao := daos.New(db)
	samples, err := dao.FindCollectionByNameOrId("samples")
	if err != nil {
		return err
	}
	for _, n := range []string{"timezone_source", "collecting_day"} {
		if f := samples.Schema.GetFieldByName(n); f != nil {
			samples.Schema.RemoveField(f.Id)
		}
	}
	if f := samples.Schema.GetFieldByName("timezone"); f != nil {
		f.Name = "time_zone"
	}
	for _, n := range []string{"elevation_dem", "elevation_dem_accuracy"} {
		if samples.Schema.GetFieldByName(n) == nil {
			samples.Schema.AddField(&schema.SchemaField{Name: n, Type: schema.FieldTypeNumber})
		}
	}
	if err := dao.SaveCollection(samples); err != nil {
		return err
	}
	fieldtrips, err := dao.FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		return err
	}
	if f := fieldtrips.Schema.GetFieldByName("timezone"); f != nil {
		fieldtrips.Schema.RemoveField(f.Id)
		if err := dao.SaveCollection(fieldtrips); err != nil {
			return err
		}
	}
	users, err := dao.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	for _, n := range []string{"sample_id_format", "sample_id_prefix", "sample_id_offset"} {
		if f := users.Schema.GetFieldByName(n); f != nil {
			users.Schema.RemoveField(f.Id)
		}
	}
	return dao.SaveCollection(users)
}

func init() {
	m.Register(phaseZUp, phaseZDown)
}
