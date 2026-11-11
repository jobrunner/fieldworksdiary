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

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"
	"github.com/pocketbase/pocketbase/tools/router"
)

// RegisterLabelRoutes wires the custom label-PDF endpoints under
// /api/label-pdfs/*.
func RegisterLabelRoutes(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		bindLabelRoutes(se.Router)
		return se.Next()
	})
}

// bindLabelRoutes mounts the label routes. PocketBase's global
// loadAuthToken middleware fills e.Auth for every route, so
// RequireAuth("users") works as a short-circuit 401-guard for
// unauthenticated requests.
func bindLabelRoutes(r *router.Router[*core.RequestEvent]) {
	r.POST("/api/label-pdfs/locality", handleLocalityLabel).Bind(apis.RequireAuth("users"))
	r.POST("/api/label-pdfs/determination", handleDeterminationLabel).Bind(apis.RequireAuth("users"))
}

type labelRequest struct {
	SampleIDs []string `json:"sample_ids"`
	Template  string   `json:"template"`
}

func handleLocalityLabel(e *core.RequestEvent) error {
	req, err := readLabelRequest(e)
	if err != nil {
		return err
	}
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	labels, sampleRecs, err := loadLocalityLabels(e.App, req.SampleIDs, ownerID)
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
	return saveLabelPDF(e, "locality", req, pdfBytes, sampleRecs, ownerID)
}

func handleDeterminationLabel(e *core.RequestEvent) error {
	req, err := readLabelRequest(e)
	if err != nil {
		return err
	}
	ownerID, err := authOwnerID(e)
	if err != nil {
		return err
	}
	labels, sampleRecs, skipped, err := loadDeterminationLabels(e.App, req.SampleIDs)
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
	return saveLabelPDF(e, "determination", req, pdfBytes, sampleRecs, ownerID)
}

// authOwnerID returns the id of the authenticated `users` record
// (e.Auth, filled by PocketBase's global loadAuthToken middleware).
//
// The RequireAuth("users") guard on the route ensures we never reach
// here without one, but we check defensively in case someone removes
// the guard later. Superusers are no owner (0.22 admins were no auth
// record either).
func authOwnerID(e *core.RequestEvent) (string, error) {
	if e.Auth != nil && !e.Auth.IsSuperuser() {
		return e.Auth.Id, nil
	}
	return "", apis.NewUnauthorizedError("authentication required", nil)
}

// assertOwnerOnSamples ensures every loaded sample belongs to the
// authenticated user. Without this an attacker with a valid token
// could guess a sample id of another user and pull its label.
// DAO operations bypass collection rules so we have to check here.
func assertOwnerOnSamples(samples []*core.Record, ownerID string) error {
	for _, s := range samples {
		if s.GetString("owner") != ownerID {
			return apis.NewForbiddenError(
				"sample does not belong to authenticated user", nil,
			)
		}
	}
	return nil
}

func readLabelRequest(e *core.RequestEvent) (labelRequest, error) {
	var req labelRequest
	if err := bindJSON(e, &req); err != nil {
		return req, err
	}
	if len(req.SampleIDs) == 0 {
		return req, apis.NewBadRequestError("sample_ids is required.", nil)
	}
	if req.Template == "" {
		req.Template = "default"
	}
	return req, nil
}

func saveLabelPDF(e *core.RequestEvent,
	kind string, req labelRequest, pdfBytes []byte,
	sampleRecs []*core.Record, ownerID string,
) error {
	coll, err := e.App.FindCollectionByNameOrId("label_pdfs")
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

	record := core.NewRecord(coll)
	record.Load(map[string]any{
		"kind":              kind,
		"template":          req.Template,
		"generation_params": string(paramsJSON),
		"samples":           sampleIDs,
		"owner":             ownerID,
	})
	record.Set("pdf_file", file)
	// Validated save (0.22: forms.RecordUpsert.Submit).
	if err := e.App.Save(record); err != nil {
		return apis.NewBadRequestError("Failed to save label_pdfs.", err)
	}
	return e.JSON(http.StatusOK, record)
}

// ---- Loaders ---------------------------------------------------------------

func loadLocalityLabels(dao core.App, sampleIDs []string, ownerID string) ([]pdf.SampleLabel, []*core.Record, error) {
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
func loadDeterminationLabels(dao core.App, sampleIDs []string) ([]pdf.DeterminationLabel, []*core.Record, int, error) {
	samples, err := dao.FindRecordsByIds("samples", sampleIDs)
	if err != nil {
		return nil, nil, 0, err
	}

	// Pre-load people so we don't repeat a query per label.
	peopleByID := map[string]*core.Record{}
	if peopleRecs, err := dao.FindAllRecords("people"); err == nil {
		for _, p := range peopleRecs {
			peopleByID[p.Id] = p
		}
	}

	var labels []pdf.DeterminationLabel
	var matched []*core.Record
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

func mostRecentDetermination(dao core.App, sampleID string) (*core.Record, error) {
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

func determinationToLabel(s *core.Record, det *core.Record, peopleByID map[string]*core.Record) pdf.DeterminationLabel {
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

func batchLoadFieldtrips(dao core.App, samples []*core.Record) (map[string]*core.Record, error) {
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
	out := map[string]*core.Record{}
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
func batchLoadPlacemarks(dao core.App, samples []*core.Record, ownerID string) (map[string]*core.Record, error) {
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
	out := map[string]*core.Record{}
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
func sampleToLabel(s *core.Record, ft *core.Record, pm *core.Record) pdf.SampleLabel {
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
