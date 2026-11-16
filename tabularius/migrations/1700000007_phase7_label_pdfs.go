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
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(func(app core.App) error {
		samples, err := app.FindCollectionByNameOrId("samples")
		if err != nil {
			return err
		}

		labelPDFs := newBaseCollection("label_pdfs",
			&core.SelectField{
				Name:      "kind",
				Required:  true,
				Values:    []string{"locality", "determination"},
				MaxSelect: 1,
			},
			&core.FileField{
				Name:      "pdf_file",
				Required:  true,
				MaxSelect: 1,
				MaxSize:   10 * 1024 * 1024,
				MimeTypes: []string{"application/pdf"},
			},
			&core.RelationField{
				Name:          "samples",
				CollectionId:  samples.Id,
				CascadeDelete: false,
				MinSelect:     0,
				MaxSelect:     manyRelations, // many
			},
			&core.TextField{Name: "template"},
			&core.JSONField{Name: "generation_params", MaxSize: 1 << 20},
		)
		labelPDFs.Indexes = types.JSONArray[string]{
			"CREATE INDEX idx_label_pdfs_kind ON label_pdfs (kind)",
			"CREATE INDEX idx_label_pdfs_created ON label_pdfs (created)",
		}
		// open rules; auth-gated in a later phase.
		labelPDFs.ListRule = types.Pointer("")
		labelPDFs.ViewRule = types.Pointer("")
		labelPDFs.CreateRule = types.Pointer("")
		labelPDFs.UpdateRule = types.Pointer("")
		labelPDFs.DeleteRule = types.Pointer("")
		if err := app.Save(labelPDFs); err != nil {
			return err
		}

		// Add the self-relation: superseded_by points back at
		// label_pdfs. We need the collection id, which we only have
		// after the first save.
		labelPDFs.Fields.Add(&core.RelationField{
			Name:          "superseded_by",
			CollectionId:  labelPDFs.Id,
			CascadeDelete: false,
			MinSelect:     0,
			MaxSelect:     1,
		})
		return app.Save(labelPDFs)
	}, func(app core.App) error {
		return deleteCollectionIfExists(app, "label_pdfs")
	})
}
