// Phase 7 — label_pdfs collection.
//
// One row per generated PDF; the PDF itself is attached as a file
// field. `samples` is a many-relation pointing at every sample
// printed on this PDF (so we can find all PDFs that contain a given
// sample). `superseded_by` chains reprints: when the user regenerates
// a corrected version of an earlier label, the old record stays
// untouched but points at its successor.
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
		samples, err := dao.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}

		labelPDFs := &models.Collection{
			Name: "label_pdfs",
			Type: models.CollectionTypeBase,
			Schema: schema.NewSchema(
				&schema.SchemaField{
					Name:     "kind",
					Type:     schema.FieldTypeSelect,
					Required: true,
					Options: &schema.SelectOptions{
						Values:    []string{"locality", "determination"},
						MaxSelect: 1,
					},
				},
				&schema.SchemaField{
					Name:     "pdf_file",
					Type:     schema.FieldTypeFile,
					Required: true,
					Options: &schema.FileOptions{
						MaxSelect: 1,
						MaxSize:   10 * 1024 * 1024,
						MimeTypes: []string{"application/pdf"},
					},
				},
				&schema.SchemaField{
					Name: "samples",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  samples.Id,
						CascadeDelete: false,
						MinSelect:     types.Pointer(0),
						MaxSelect:     nil, // many
					},
				},
				&schema.SchemaField{Name: "template", Type: schema.FieldTypeText},
				&schema.SchemaField{
					Name: "generation_params",
					Type: schema.FieldTypeJson,
					Options: &schema.JsonOptions{MaxSize: 1 << 20},
				},
				&schema.SchemaField{
					Name: "superseded_by",
					Type: schema.FieldTypeRelation,
					Options: &schema.RelationOptions{
						CollectionId:  "", // self — filled below
						CascadeDelete: false,
						MinSelect:     types.Pointer(0),
						MaxSelect:     types.Pointer(1),
					},
				},
			),
			Indexes: types.JsonArray[string]{
				"CREATE INDEX idx_label_pdfs_kind ON label_pdfs (kind)",
				"CREATE INDEX idx_label_pdfs_created ON label_pdfs (created)",
			},
			// open rules; auth-gated in a later phase.
			ListRule:   types.Pointer(""),
			ViewRule:   types.Pointer(""),
			CreateRule: types.Pointer(""),
			UpdateRule: types.Pointer(""),
			DeleteRule: types.Pointer(""),
		}
		if err := dao.SaveCollection(labelPDFs); err != nil {
			return err
		}

		// Patch the self-relation: superseded_by points back at
		// label_pdfs. We need the collection id, which we only have
		// after the first save.
		for _, f := range labelPDFs.Schema.Fields() {
			if f.Name == "superseded_by" {
				if opts, ok := f.Options.(*schema.RelationOptions); ok {
					opts.CollectionId = labelPDFs.Id
				}
			}
		}
		return dao.SaveCollection(labelPDFs)
	}, func(db dbx.Builder) error {
		dao := daos.New(db)
		if c, err := dao.FindCollectionByNameOrId("label_pdfs"); err == nil {
			return dao.DeleteCollection(c)
		}
		return nil
	})
}
