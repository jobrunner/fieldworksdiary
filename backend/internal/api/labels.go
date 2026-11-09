// Package api contains the custom HTTP routes that PocketBase's
// auto-generated REST API doesn't cover — PDF label generation in
// particular. Routes are registered from main.go via
// RegisterLabelRoutes.
package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"go.mett.io/fwd-backend/internal/geoplace"
	"go.mett.io/fwd-backend/internal/pdf"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/forms"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tools/filesystem"
)

// RegisterLabelRoutes wires the custom label-PDF endpoints under
// /api/label-pdfs/*.
func RegisterLabelRoutes(app core.App) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		// PocketBase's e.Pre(LoadAuthContext) already populates
		// the `authRecord` context key for every route, so
		// RequireRecordAuth("users") works as a short-circuit
		// 401-guard for unauthenticated requests.
		requireAuth := apis.RequireRecordAuth("users")
		e.Router.POST("/api/label-pdfs/locality", func(c echo.Context) error {
			return handleLocalityLabel(app, c)
		}, requireAuth)
		e.Router.POST("/api/label-pdfs/determination", func(c echo.Context) error {
			return handleDeterminationLabel(app, c)
		}, requireAuth)
		return nil
	})
}

type labelRequest struct {
	SampleIDs []string `json:"sample_ids"`
	Template  string   `json:"template"`
}

func handleLocalityLabel(app core.App, c echo.Context) error {
	req, err := readLabelRequest(c)
	if err != nil {
		return err
	}
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	dao := app.Dao()
	labels, sampleRecs, err := loadLocalityLabels(dao, req.SampleIDs, ownerID)
	if err != nil {
		return apis.NewBadRequestError("Failed to load samples.", err)
	}
	if err := assertOwnerOnSamples(sampleRecs, ownerID); err != nil {
		return err
	}
	if len(labels) == 0 {
		return apis.NewBadRequestError("No matching samples found.", nil)
	}

	layout := pdf.LayoutFromTemplate(req.Template)
	pdfBytes, err := pdf.RenderLocalityLabels(labels, layout)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Render failed.", err)
	}
	return saveLabelPDF(app, c, "locality", req, pdfBytes, sampleRecs, ownerID)
}

func handleDeterminationLabel(app core.App, c echo.Context) error {
	req, err := readLabelRequest(c)
	if err != nil {
		return err
	}
	ownerID, err := authOwnerID(c)
	if err != nil {
		return err
	}
	dao := app.Dao()
	labels, sampleRecs, skipped, err := loadDeterminationLabels(dao, req.SampleIDs)
	if err != nil {
		return apis.NewBadRequestError("Failed to load samples.", err)
	}
	if err := assertOwnerOnSamples(sampleRecs, ownerID); err != nil {
		return err
	}
	if len(labels) == 0 {
		return apis.NewBadRequestError(
			fmt.Sprintf("No samples have a determination yet (skipped %d).", skipped),
			nil,
		)
	}

	layout := pdf.LayoutFromTemplate(req.Template)
	pdfBytes, err := pdf.RenderDeterminationLabels(labels, layout)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Render failed.", err)
	}
	return saveLabelPDF(app, c, "determination", req, pdfBytes, sampleRecs, ownerID)
}

// authOwnerID extracts the authenticated user id directly from the
// auth-record context. The `ContextRequestInfoKey` is only populated
// by PocketBase's collection-handling middlewares — custom routes
// like ours get the raw auth record via `ContextAuthRecordKey`
// from the global LoadAuthContext pre-middleware.
//
// The RequireRecordAuth("users") guard on the route ensures we
// never reach here without an auth record, but we type-check
// defensively in case someone removes the guard later.
func authOwnerID(c echo.Context) (string, error) {
	if rec, _ := c.Get(apis.ContextAuthRecordKey).(*models.Record); rec != nil {
		return rec.Id, nil
	}
	return "", apis.NewUnauthorizedError("authentication required", nil)
}

// assertOwnerOnSamples ensures every loaded sample belongs to the
// authenticated user. Without this an attacker with a valid token
// could guess a sample id of another user and pull its label.
// DAO operations bypass collection rules so we have to check here.
func assertOwnerOnSamples(samples []*models.Record, ownerID string) error {
	for _, s := range samples {
		if s.GetString("owner") != ownerID {
			return apis.NewForbiddenError(
				"sample does not belong to authenticated user", nil,
			)
		}
	}
	return nil
}

func readLabelRequest(c echo.Context) (labelRequest, error) {
	var req labelRequest
	if err := c.Bind(&req); err != nil {
		return req, apis.NewBadRequestError("Invalid request body.", err)
	}
	if len(req.SampleIDs) == 0 {
		return req, apis.NewBadRequestError("sample_ids is required.", nil)
	}
	if req.Template == "" {
		req.Template = "default"
	}
	return req, nil
}

func saveLabelPDF(app core.App, c echo.Context,
	kind string, req labelRequest, pdfBytes []byte,
	sampleRecs []*models.Record, ownerID string,
) error {
	dao := app.Dao()
	coll, err := dao.FindCollectionByNameOrId("label_pdfs")
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Missing label_pdfs collection.", err)
	}

	filename := fmt.Sprintf("%s-%s.pdf", kind, time.Now().UTC().Format("20060102-150405"))
	file, err := filesystem.NewFileFromBytes(pdfBytes, filename)
	if err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Wrap PDF as file.", err)
	}

	paramsJSON, _ := json.Marshal(req)
	sampleIDs := make([]string, 0, len(sampleRecs))
	for _, s := range sampleRecs {
		sampleIDs = append(sampleIDs, s.Id)
	}

	record := models.NewRecord(coll)
	form := forms.NewRecordUpsert(app, record)
	if err := form.LoadData(map[string]any{
		"kind":              kind,
		"template":          req.Template,
		"generation_params": string(paramsJSON),
		"samples":           sampleIDs,
		"owner":             ownerID,
	}); err != nil {
		return apis.NewBadRequestError("Bad payload for label_pdfs.", err)
	}
	if err := form.AddFiles("pdf_file", file); err != nil {
		return apis.NewApiError(http.StatusInternalServerError, "Attach PDF.", err)
	}
	if err := form.Submit(); err != nil {
		return apis.NewBadRequestError("Failed to save label_pdfs.", err)
	}
	return c.JSON(http.StatusOK, record)
}

// ---- Loaders ---------------------------------------------------------------

func loadLocalityLabels(dao *daos.Dao, sampleIDs []string, ownerID string) ([]pdf.SampleLabel, []*models.Record, error) {
	samples, err := dao.FindRecordsByIds("samples", sampleIDs)
	if err != nil {
		return nil, nil, err
	}
	ftByID, err := batchLoadFieldtrips(dao, samples)
	if err != nil {
		return nil, nil, err
	}
	pmByID, err := batchLoadPlacemarks(dao, samples, ownerID)
	if err != nil {
		return nil, nil, err
	}
	labels := make([]pdf.SampleLabel, 0, len(samples))
	for _, s := range samples {
		labels = append(labels, sampleToLabel(s, ftByID[s.GetString("fieldtrip")], pmByID[s.GetString("placemark")]))
	}
	return labels, samples, nil
}

// loadDeterminationLabels returns one DeterminationLabel per sample
// that has at least one determination — most-recent `det.` first,
// otherwise the most-recent of any kind. Samples without any
// determination are silently skipped; the count goes back to the
// caller so they can surface "skipped N" in the response.
func loadDeterminationLabels(dao *daos.Dao, sampleIDs []string) ([]pdf.DeterminationLabel, []*models.Record, int, error) {
	samples, err := dao.FindRecordsByIds("samples", sampleIDs)
	if err != nil {
		return nil, nil, 0, err
	}

	// Pre-load people so we don't repeat a query per label.
	peopleByID := map[string]*models.Record{}
	if peopleRecs, err := dao.FindRecordsByExpr("people"); err == nil {
		for _, p := range peopleRecs {
			peopleByID[p.Id] = p
		}
	}

	var labels []pdf.DeterminationLabel
	var matched []*models.Record
	skipped := 0
	for _, s := range samples {
		det, err := mostRecentDetermination(dao, s.Id)
		if err != nil || det == nil {
			skipped++
			continue
		}
		labels = append(labels, determinationToLabel(s, det, peopleByID))
		matched = append(matched, s)
	}
	return labels, matched, skipped, nil
}

func mostRecentDetermination(dao *daos.Dao, sampleID string) (*models.Record, error) {
	// Prefer det.; fall back to any kind. Both queries pick the most
	// recent by `determined_on` (and `created` as a stable tiebreak).
	prefer, err := dao.FindRecordsByFilter(
		"determinations",
		"sample = {:sid} && kind = 'det'",
		"-determined_on,-created",
		1, 0,
		dbx.Params{"sid": sampleID},
	)
	if err == nil && len(prefer) > 0 {
		return prefer[0], nil
	}
	any, err := dao.FindRecordsByFilter(
		"determinations",
		"sample = {:sid}",
		"-determined_on,-created",
		1, 0,
		dbx.Params{"sid": sampleID},
	)
	if err != nil || len(any) == 0 {
		// "Keine Determination zum Sample" ist hier kein Fehler, sondern
		// erwartetes Skip-Signal an den Aufrufer (Label ohne Det.-Block
		// rendern). Wir verschlucken den FindRecords-Fehler bewusst, weil
		// er ohnehin nur ein leerer Result-Set wäre.
		return nil, nil //nolint:nilerr // intentional: not-found = skip
	}
	return any[0], nil
}

func determinationToLabel(s *models.Record, det *models.Record, peopleByID map[string]*models.Record) pdf.DeterminationLabel {
	l := pdf.DeterminationLabel{
		Code:         s.GetString("sample_id"),
		SpeciesText:  det.GetString("species_text"),
		Kind:         det.GetString("kind"),
		DeterminedOn: det.GetDateTime("determined_on").Time(),
	}
	if pid := det.GetString("person"); pid != "" {
		if p := peopleByID[pid]; p != nil {
			abbrev := p.GetString("abbreviation")
			if abbrev == "" {
				abbrev = p.GetString("full_name")
			}
			l.PersonAbbrev = abbrev
		}
	}
	return l
}

func batchLoadFieldtrips(dao *daos.Dao, samples []*models.Record) (map[string]*models.Record, error) {
	ftIDs := make(map[string]struct{})
	for _, s := range samples {
		if id := s.GetString("fieldtrip"); id != "" {
			ftIDs[id] = struct{}{}
		}
	}
	ids := make([]string, 0, len(ftIDs))
	for id := range ftIDs {
		ids = append(ids, id)
	}
	out := map[string]*models.Record{}
	if len(ids) == 0 {
		return out, nil
	}
	recs, err := dao.FindRecordsByIds("fieldtrips", ids)
	if err != nil {
		return nil, err
	}
	for _, r := range recs {
		out[r.Id] = r
	}
	return out, nil
}

// batchLoadPlacemarks loads the placemarks referenced by the samples
// in one query, keyed by record id. Placemarks the caller may not see
// (geoplace.VisibleTo) are dropped, so a foreign manual placemark never
// ends up on a label.
func batchLoadPlacemarks(dao *daos.Dao, samples []*models.Record, ownerID string) (map[string]*models.Record, error) {
	seen := make(map[string]struct{})
	ids := make([]string, 0, len(samples))
	for _, s := range samples {
		id := s.GetString("placemark")
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	out := map[string]*models.Record{}
	if len(ids) == 0 {
		return out, nil
	}
	recs, err := dao.FindRecordsByIds("placemarks", ids)
	if err != nil {
		return nil, err
	}
	for _, r := range recs {
		if geoplace.VisibleTo(r, ownerID) {
			out[r.Id] = r
		}
	}
	return out, nil
}

// sampleToLabel builds the label data for a sample. Country, state and
// municipality come from the sample's placemark (nil → left empty);
// the MTB line is no longer printed on labels.
func sampleToLabel(s *models.Record, ft *models.Record, pm *models.Record) pdf.SampleLabel {
	label := pdf.SampleLabel{
		Code:          s.GetString("sample_id"),
		Lat:           s.GetFloat("latitude"),
		Lon:           s.GetFloat("longitude"),
		HasCoords:     true,
		CollectedFrom: s.GetDateTime("begin_date").Time(),
	}
	if alt := s.GetFloat("elevation"); alt != 0 {
		label.AltitudeM = alt
		label.HasAltitude = true
	}
	if pm != nil {
		label.Country = pm.GetString("admin_country")
		label.AdminArea = pm.GetString("admin_state")
		label.Locality = pm.GetString("admin_municipality")
	}
	if ft != nil {
		label.PermitNumber = ft.GetString("permit_number")
	}
	return label
}
