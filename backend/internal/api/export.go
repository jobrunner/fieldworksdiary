package api

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"
	"github.com/pocketbase/pocketbase/tools/router"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// RegisterExportRoute wires `GET /api/export`. The endpoint returns
// a single ZIP archive containing all records owned by the
// authenticated user plus any attached PDF files (permits, label PDFs)
// pulled straight out of PocketBase's file storage.
//
// The archive is for backup. It is NOT designed as an import format —
// fields, structure, and naming may change without a migration story.
func RegisterExportRoute(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindExportRoute(se.Router)
		return se.Next()
	})
}

func bindExportRoute(r *router.Router[*core.RequestEvent]) {
	r.GET("/api/export", handleExport).Bind(apis.RequireAuth("users"))
}

// exportPayload is the JSON shape of `data.json` inside the archive.
// Anything in `meta` is for human orientation; the per-collection
// arrays carry the records as PocketBase serialises them (same shape
// the REST API would return for an authenticated GET).
type exportPayload struct {
	ExportedAt     time.Time        `json:"exported_at"`
	Meta           exportMeta       `json:"meta"`
	Samples        []map[string]any `json:"samples"`
	Fieldtrips     []map[string]any `json:"fieldtrips"`
	Localities     []map[string]any `json:"localities"`
	People         []map[string]any `json:"people"`
	Determinations []map[string]any `json:"determinations"`
	LabelPDFs      []map[string]any `json:"label_pdfs"`
	Placemarks     []map[string]any `json:"placemarks"`
	SampleFeatures []map[string]any `json:"sample_features"`
}

type exportMeta struct {
	User map[string]any `json:"user"`
}

func handleExport(e *core.RequestEvent) error {
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	app := e.App
	dao := app

	userRec, err := dao.FindRecordById("users", ownerID)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load user.", err)
	}
	userRec.IgnoreEmailVisibility(true)

	payload := exportPayload{
		ExportedAt: time.Now().UTC(),
		Meta:       exportMeta{User: userRec.PublicExport()},
	}

	if payload.Samples, err = fetchOwned(dao, "samples", ownerID, "-begin_date"); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load samples.", err)
	}
	fieldtrips, err := dao.FindRecordsByFilter("fieldtrips", "owner = {:o}", "-collecting_day", 0, 0, dbx.Params{"o": ownerID})
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load fieldtrips.", err)
	}
	payload.Fieldtrips = exportAll(fieldtrips)
	if payload.Localities, err = fetchOwned(dao, "localities", ownerID, "name"); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load localities.", err)
	}
	if payload.People, err = fetchOwned(dao, "people", ownerID, ""); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load people.", err)
	}
	if payload.Determinations, err = fetchOwned(dao, "determinations", ownerID, "-determined_on"); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load determinations.", err)
	}
	labelPDFs, err := dao.FindRecordsByFilter("label_pdfs", "owner = {:o}", "-created", 0, 0, dbx.Params{"o": ownerID})
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load label PDFs.", err)
	}
	payload.LabelPDFs = exportAll(labelPDFs)

	// Placemarks mix shared backend rows and per-user manual rows: export
	// the ones referenced by this user's samples and localities that the
	// user may see (geoplace.VisibleTo).
	if payload.Placemarks, err = exportReferencedPlacemarks(dao, ownerID); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load placemarks.", err)
	}
	if payload.SampleFeatures, err = fetchOwned(dao, "sample_features", ownerID, "sample,source_id"); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Failed to load sample features.", err)
	}

	// Stream the ZIP into the response. Setting headers before we
	// write the first byte means errors hereafter become broken
	// downloads — but the alternative (buffer the whole archive in
	// memory) is worse once PDFs are involved.
	filename := fmt.Sprintf("fieldworksdiary-export-%s.zip", time.Now().UTC().Format("20060102-150405"))
	e.Response.Header().Set("Content-Type", "application/zip")
	e.Response.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	e.Response.WriteHeader(http.StatusOK)

	zw := zip.NewWriter(e.Response)
	defer zw.Close()

	if err := writeJSON(zw, "data.json", payload); err != nil {
		return err
	}

	fs, err := app.NewFilesystem()
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Filesystem unavailable.", err)
	}
	defer fs.Close()

	// Permit PDFs from fieldtrips.
	for _, ft := range fieldtrips {
		name := ft.GetString("permit_pdf")
		if name == "" {
			continue
		}
		key := path.Join(ft.BaseFilesPath(), name)
		entry := path.Join("pdfs", "fieldtrips", ft.Id, name)
		if err := copyFromStorage(zw, fs, key, entry); err != nil {
			// Soft-fail: a missing PDF should not break the entire
			// export. Skip with a note in the ZIP root instead.
			writeText(zw, fmt.Sprintf("missing/%s.txt", ft.Id),
				fmt.Sprintf("permit PDF %q for fieldtrip %s could not be read: %v\n", name, ft.Id, err))
		}
	}

	// Label PDFs.
	for _, l := range labelPDFs {
		name := l.GetString("pdf_file")
		if name == "" {
			continue
		}
		key := path.Join(l.BaseFilesPath(), name)
		entry := path.Join("pdfs", "labels", l.Id, name)
		if err := copyFromStorage(zw, fs, key, entry); err != nil {
			writeText(zw, fmt.Sprintf("missing/%s.txt", l.Id),
				fmt.Sprintf("label PDF %q for label %s could not be read: %v\n", name, l.Id, err))
		}
	}

	return nil
}

func fetchOwned(dao interface {
	FindRecordsByFilter(any, string, string, int, int, ...dbx.Params) ([]*core.Record, error)
}, name, ownerID, sort string,
) ([]map[string]any, error) {
	recs, err := dao.FindRecordsByFilter(name, "owner = {:o}", sort, 0, 0, dbx.Params{"o": ownerID})
	if err != nil {
		return nil, err
	}
	return exportAll(recs), nil
}

// exportReferencedPlacemarks returns the placemarks (and suggested
// placemarks) referenced by the owner's samples and localities.
func exportReferencedPlacemarks(dao core.App, ownerID string) ([]map[string]any, error) {
	seen := map[string]struct{}{}
	var ids []string
	add := func(coll string, fields ...string) error {
		recs, err := dao.FindRecordsByFilter(coll, "owner = {:o}", "", 0, 0, dbx.Params{"o": ownerID})
		if err != nil {
			return err
		}
		for _, r := range recs {
			for _, f := range fields {
				id := r.GetString(f)
				if id == "" {
					continue
				}
				if _, ok := seen[id]; ok {
					continue
				}
				seen[id] = struct{}{}
				ids = append(ids, id)
			}
		}
		return nil
	}
	if err := add("samples", "placemark", "placemark_suggestion"); err != nil {
		return nil, err
	}
	if err := add("localities", "placemark"); err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return []map[string]any{}, nil
	}
	recs, err := dao.FindRecordsByIds("placemarks", ids)
	if err != nil {
		return nil, err
	}
	// Mirror the collection's view rule: shared backend rows or own rows.
	visible := recs[:0]
	for _, r := range recs {
		if geoplace.VisibleTo(r, ownerID) {
			visible = append(visible, r)
		}
	}
	return exportAll(visible), nil
}

func exportAll(recs []*core.Record) []map[string]any {
	out := make([]map[string]any, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.PublicExport())
	}
	return out
}

func writeJSON(zw *zip.Writer, name string, v any) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func writeText(zw *zip.Writer, name, body string) {
	if w, err := zw.Create(name); err == nil {
		_, _ = io.WriteString(w, body)
	}
}

func copyFromStorage(zw *zip.Writer, fs *filesystem.System, key, entry string) error {
	r, err := fs.GetReader(key)
	if err != nil {
		return err
	}
	defer r.Close()
	w, err := zw.Create(entry)
	if err != nil {
		return err
	}
	_, err = io.Copy(w, r)
	return err
}
