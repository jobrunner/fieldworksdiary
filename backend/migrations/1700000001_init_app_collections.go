// Phase 1 — initial collections: localities, excursions, samples,
// sample_sequences. Rules are wide open ("" = anyone, including
// unauthenticated) for the dev bootstrap; auth is wired in a later
// phase.
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(db dbx.Builder) error {
		dao := daos.New(db)

		open := types.Pointer("")

		// 1. localities
		localities := &models.Collection{
			Name: "localities",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "name", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "centroid_lat", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "centroid_lon", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "radius_m", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "notes", Type: schema.FieldTypeEditor},
			),
			ListRule:   open,
			ViewRule:   open,
			CreateRule: open,
			UpdateRule: open,
			DeleteRule: open,
		}
		if err := dao.SaveCollection(localities); err != nil {
			return err
		}

		// 2. excursions  (relation → localities)
		//
		// user_id, started_at, ended_at, collecting_day are populated
		// by the sample-create hook, never by the client. Schema-level
		// `Required` is therefore off — the hook is the single source
		// of truth, and PocketBase validation runs *before* the hook
		// so requiring them here would just reject every legit insert.
		excursions := &models.Collection{
			Name: "excursions",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "name", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "user_id", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "started_at", Type: schema.FieldTypeDate},
				&schema.SchemaField{Name: "ended_at", Type: schema.FieldTypeDate},
				// collecting_day stored as YYYY-MM-DD (PocketBase has no
				// date-only type; using text keeps the value uniform
				// across SQLite and JSON).
				&schema.SchemaField{Name: "collecting_day", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "night_excursion", Type: schema.FieldTypeBool},
				&schema.SchemaField{Name: "centroid_lat", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "centroid_lon", Type: schema.FieldTypeNumber},
				&schema.SchemaField{
					Name: "locality",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  localities.Id,
						CascadeDelete: false,
						MinSelect:     types.Pointer(0),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "client_uuid", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "client_updated_at", Type: schema.FieldTypeDate},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_excursions_user_day ON excursions (user_id, collecting_day)",
			},
			ListRule:   open,
			ViewRule:   open,
			CreateRule: open,
			UpdateRule: open,
			DeleteRule: open,
		}
		if err := dao.SaveCollection(excursions); err != nil {
			return err
		}

		// 3. samples  (relation → excursions)
		samples := &models.Collection{
			Name: "samples",
			Type: models.CollectionTypeBase,
			// `code`, `excursion`, `user_id` are filled by the
			// before-create hook; not Required at schema level (see
			// note on excursions). `lat` / `lon` come from the client.
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "code", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "original_code", Type: schema.FieldTypeText},
				&schema.SchemaField{
					Name: "excursion",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  excursions.Id,
						CascadeDelete: false,
						MinSelect:     types.Pointer(0),
						MaxSelect:     types.Pointer(1),
					},
				},
				&schema.SchemaField{Name: "user_id", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "collected_from", Type: schema.FieldTypeDate},
				&schema.SchemaField{Name: "collected_to", Type: schema.FieldTypeDate},
				&schema.SchemaField{Name: "lat", Type: schema.FieldTypeNumber, Required: true},
				&schema.SchemaField{Name: "lon", Type: schema.FieldTypeNumber, Required: true},
				&schema.SchemaField{Name: "altitude_m", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "accuracy_m", Type: schema.FieldTypeNumber},
				&schema.SchemaField{Name: "notes", Type: schema.FieldTypeEditor},
				&schema.SchemaField{Name: "client_uuid", Type: schema.FieldTypeText},
				&schema.SchemaField{Name: "client_updated_at", Type: schema.FieldTypeDate},
			),
			Indexes: types.JsonArray[string]{
				"CREATE UNIQUE INDEX idx_samples_code ON samples (code)",
				"CREATE INDEX idx_samples_excursion ON samples (excursion)",
			},
			ListRule:   open,
			ViewRule:   open,
			CreateRule: open,
			UpdateRule: open,
			DeleteRule: open,
		}
		if err := dao.SaveCollection(samples); err != nil {
			return err
		}

		// 4. sample_sequences  (atomic counter per user × collecting_day)
		sequences := &models.Collection{
			Name: "sample_sequences",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{Name: "user_id", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "collecting_day", Type: schema.FieldTypeText, Required: true},
				&schema.SchemaField{Name: "last_seq", Type: schema.FieldTypeNumber, Required: true},
			),
			Indexes: types.JsonArray[string]{
				"CREATE UNIQUE INDEX idx_sample_sequences_user_day ON sample_sequences (user_id, collecting_day)",
			},
			// sequence rows are written exclusively by the server-side
			// hook; clients have no business touching them.
			ListRule:   nil,
			ViewRule:   nil,
			CreateRule: nil,
			UpdateRule: nil,
			DeleteRule: nil,
		}
		if err := dao.SaveCollection(sequences); err != nil {
			return err
		}

		return nil
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		// reverse order — samples and sample_sequences first, then
		// excursions, then localities.
		for _, name := range []string{"samples", "sample_sequences", "excursions", "localities"} {
			col, err := dao.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			if err := dao.DeleteCollection(col); err != nil {
				return err
			}
		}
		return nil
	})
}
