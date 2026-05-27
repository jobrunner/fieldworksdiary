package enrichment

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/services"
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// ────────────────────────────────────────────────────────────────────
// Pure-Function-Tests — keine DB, kein Netz
// ────────────────────────────────────────────────────────────────────

func TestLocalityFromAdminUnits(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"happy", `{"locality":"Würzburg","country":"DE"}`, "Würzburg"},
		{"missing field", `{"country":"DE"}`, ""},
		{"empty json", `{}`, ""},
		{"malformed", `{not-json`, ""},
		{"empty string", ``, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := localityFromAdminUnits(c.raw); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestHasDefaultPrefix(t *testing.T) {
	cases := map[string]bool{
		"Sammeltag 19.05.2026": true,
		"Sammeltag":            false, // ohne trailing-Space → kein Default
		"Heidehöhe":            false,
		"":                     false,
		"Sammeltag X":          true,
	}
	for input, want := range cases {
		t.Run(input, func(t *testing.T) {
			if got := hasDefaultPrefix(input); got != want {
				t.Errorf("hasDefaultPrefix(%q) = %v, want %v", input, got, want)
			}
		})
	}
}

func TestCentroid_EmptyReturnsZero(t *testing.T) {
	lat, lon := centroid(nil)
	if lat != 0 || lon != 0 {
		t.Errorf("centroid(nil) = (%v, %v), want (0, 0)", lat, lon)
	}
}

func TestCentroid_AveragesLatLon(t *testing.T) {
	app := newAppForRecordsOnly(t)
	coll, _ := app.Dao().FindCollectionByNameOrId("samples")

	mk := func(lat, lon float64) *models.Record {
		r := models.NewRecord(coll)
		r.Set("latitude", lat)
		r.Set("longitude", lon)
		return r
	}
	samples := []*models.Record{
		mk(49.0, 9.0),
		mk(51.0, 11.0),
	}
	lat, lon := centroid(samples)
	if lat != 50.0 || lon != 10.0 {
		t.Errorf("centroid = (%v, %v), want (50.0, 10.0)", lat, lon)
	}
}

func TestDecodeAdminUnits(t *testing.T) {
	cases := []struct {
		name      string
		raw       string
		wantNil   bool
		wantField string
	}{
		{"happy", `{"locality":"Würzburg","adminArea":"Bayern","country":"DE"}`, false, "Würzburg"},
		{"empty", ``, true, ""},
		{"malformed", `[1,2,3]`, true, ""}, // Array statt Object → Unmarshal-Fehler
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := decodeAdminUnits(c.raw)
			if c.wantNil {
				if got != nil {
					t.Errorf("got %v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("got nil, want non-nil")
			}
			if got.Locality != c.wantField {
				t.Errorf("Locality = %q, want %q", got.Locality, c.wantField)
			}
		})
	}
}

func TestParseCollectingDay_AnchorsAtNoon(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	day := parseCollectingDay("2026-05-19", loc)
	if h := day.Hour(); h != 12 {
		t.Errorf("hour = %d, want 12 (Anker auf Mittag wegen DST)", h)
	}
	if day.Location().String() != "Europe/Berlin" {
		t.Errorf("location = %q, want Europe/Berlin", day.Location())
	}
}

func TestParseCollectingDay_InvalidFormatFallsBackToNow(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	day := parseCollectingDay("not-a-date", loc)
	if time.Since(day) > time.Second {
		t.Errorf("fallback day too old: %v", day)
	}
}

// ────────────────────────────────────────────────────────────────────
// Integration mit echtem PB-Test-App + httptest-Fake-Services
// ────────────────────────────────────────────────────────────────────

func newAppForRecordsOnly(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

// fakeServices spinnt zwei httptest-Server hoch, die Labelloc- und
// MTB-Responses simulieren. Beide Behaviors steuerbar via Felder.
type fakeServices struct {
	t              *testing.T
	labelloc       *httptest.Server
	mtb            *httptest.Server
	labellocLocale string
	labellocFail   bool
	labellocHits   int
	mtbHits        int
}

func newFakeServices(t *testing.T) *fakeServices {
	t.Helper()
	f := &fakeServices{t: t, labellocLocale: "Würzburg"}
	f.labelloc = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.labellocHits++
		if f.labellocFail {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{
				"country":   "Deutschland",
				"adminArea": "Bayern",
				"locality":  f.labellocLocale,
			},
			"status": map[string]any{"code": 200, "message": "OK"},
		})
	}))
	t.Cleanup(f.labelloc.Close)

	f.mtb = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mtbHits++
		_ = json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{
				"sheet_number": "6225",
				"sheet_name":   "Würzburg Nord",
				"quadrant":     3,
				"found":        true,
			},
			"status": map[string]any{"code": 200, "message": "OK"},
		})
	}))
	t.Cleanup(f.mtb.Close)
	return f
}

func (f *fakeServices) labellocClient() *services.Labelloc {
	return &services.Labelloc{
		BaseURL:    f.labelloc.URL,
		HTTPClient: &http.Client{Timeout: 2 * time.Second},
		MaxRetries: 1,
	}
}

func (f *fakeServices) mtbClient() *services.MTB {
	return &services.MTB{
		BaseURL:    f.mtb.URL,
		HTTPClient: &http.Client{Timeout: 2 * time.Second},
		MaxRetries: 1,
	}
}

// createOwnerSampleFieldtrip legt einen User + eine Fieldtrip + ein
// Sample mit (lat, lon) an. Owner-Beziehungen werden direkt gesetzt,
// damit wir keine Hook-Cascade brauchen.
func createOwnerSampleFieldtrip(t *testing.T, app *tests.TestApp, lat, lon float64) (ownerID, sampleID, ftID string) {
	t.Helper()
	dao := app.Dao()

	usersColl, _ := dao.FindCollectionByNameOrId("users")
	user := models.NewRecord(usersColl)
	if err := user.SetEmail("enrich-" + strings.ReplaceAll(t.Name(), "/", "_") + "@example.com"); err != nil {
		t.Fatalf("set email: %v", err)
	}
	if err := user.SetUsername("enrichuser_" + strings.ReplaceAll(t.Name(), "/", "_")); err != nil {
		t.Fatalf("set username: %v", err)
	}
	if err := user.SetPassword("test1234password"); err != nil {
		t.Fatalf("set password: %v", err)
	}
	if err := dao.SaveRecord(user); err != nil {
		t.Fatalf("save user: %v", err)
	}

	ftColl, _ := dao.FindCollectionByNameOrId("fieldtrips")
	ft := models.NewRecord(ftColl)
	ft.Set("owner", user.Id)
	ft.Set("collecting_day", "2026-05-19")
	ft.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, time.UTC))
	ft.Set("end_date", time.Date(2026, 5, 19, 16, 0, 0, 0, time.UTC))
	if err := dao.SaveRecord(ft); err != nil {
		t.Fatalf("save fieldtrip: %v", err)
	}

	samColl, _ := dao.FindCollectionByNameOrId("samples")
	sam := models.NewRecord(samColl)
	sam.Set("owner", user.Id)
	sam.Set("fieldtrip", ft.Id)
	sam.Set("sample_id", "260519/1")
	sam.Set("latitude", lat)
	sam.Set("longitude", lon)
	sam.Set("begin_date", time.Date(2026, 5, 19, 15, 0, 0, 0, time.UTC))
	if err := dao.SaveRecord(sam); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	return user.Id, sam.Id, ft.Id
}

func TestEnricher_Run_PopulatesAdminUnitsAndMTB(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, 49.793, 9.939)

	fakes := newFakeServices(t)
	e := &Enricher{
		App:      app,
		Labelloc: fakes.labellocClient(),
		MTB:      fakes.mtbClient(),
		Timeout:  5 * time.Second,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	e.run(ctx, sampleID, 49.793, 9.939)

	// admin_units is propagated straight to the fieldtrip (R7.4 dropped
	// the per-sample column); mtb still lands on the sample.
	got, err := app.Dao().FindRecordById("samples", sampleID)
	if err != nil {
		t.Fatalf("re-fetch sample: %v", err)
	}
	if mtb := got.GetString("mtb"); !strings.Contains(mtb, "6225") {
		t.Errorf("mtb = %q, expected to contain sheet 6225", mtb)
	}
	ft, err := app.Dao().FindRecordById("fieldtrips", ftID)
	if err != nil {
		t.Fatalf("re-fetch fieldtrip: %v", err)
	}
	if au := ft.GetString("admin_units"); !strings.Contains(au, "Würzburg") {
		t.Errorf("fieldtrip.admin_units = %q, expected to contain Würzburg", au)
	}
	if fakes.labellocHits != 1 || fakes.mtbHits != 1 {
		t.Errorf("hits: labelloc=%d mtb=%d, want 1 each", fakes.labellocHits, fakes.mtbHits)
	}
}

func TestEnricher_Run_NilServicesIsNoOp(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, 49.793, 9.939)

	e := &Enricher{App: app}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	e.run(ctx, sampleID, 49.793, 9.939)

	ft, _ := app.Dao().FindRecordById("fieldtrips", ftID)
	if au := ft.GetString("admin_units"); au != "" {
		t.Errorf("fieldtrip.admin_units = %q, want empty (no service registered)", au)
	}
}

func TestEnricher_Run_LabellocFailureDoesNotBlockMTB(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, 49.793, 9.939)

	fakes := newFakeServices(t)
	fakes.labellocFail = true
	e := &Enricher{
		App:      app,
		Labelloc: fakes.labellocClient(),
		MTB:      fakes.mtbClient(),
		Timeout:  5 * time.Second,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	e.run(ctx, sampleID, 49.793, 9.939)

	got, _ := app.Dao().FindRecordById("samples", sampleID)
	if mtb := got.GetString("mtb"); !strings.Contains(mtb, "6225") {
		t.Errorf("mtb was not saved despite labelloc failure: %q", mtb)
	}
	ft, _ := app.Dao().FindRecordById("fieldtrips", ftID)
	if au := ft.GetString("admin_units"); au != "" {
		t.Errorf("fieldtrip.admin_units = %q, want empty after labelloc 500", au)
	}
}

func TestMaybePropagateToFieldtrip_FillsEmptyFields(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, 49.793, 9.939)

	// admin_units kommt jetzt als Parameter (R7.4); fieldtrip leer lassen.
	sample, _ := app.Dao().FindRecordById("samples", sampleID)
	adminUnits := `{"locality":"Würzburg","country":"DE","adminArea":"Bayern"}`

	e := &Enricher{App: app}
	e.maybePropagateToFieldtrip(sample, adminUnits)

	ft, _ := app.Dao().FindRecordById("fieldtrips", ftID)
	if au := ft.GetString("admin_units"); !strings.Contains(au, "Würzburg") {
		t.Errorf("fieldtrip.admin_units = %q, want propagated", au)
	}
	// Name war initial leer → auto-name: "Würzburg — 2026-05-19"
	if name := ft.GetString("title"); !strings.Contains(name, "Würzburg") {
		t.Errorf("fieldtrip.name = %q, want auto-promoted with locality", name)
	}
}

func TestMaybePropagateToFieldtrip_PreservesManualName(t *testing.T) {
	app := newAppForRecordsOnly(t)
	_, sampleID, ftID := createOwnerSampleFieldtrip(t, app, 49.793, 9.939)

	// User-vergebener Name → muss erhalten bleiben.
	ft, _ := app.Dao().FindRecordById("fieldtrips", ftID)
	ft.Set("title", "Heidehöhe Würzburg")
	if err := app.Dao().SaveRecord(ft); err != nil {
		t.Fatalf("save fieldtrip: %v", err)
	}

	sample, _ := app.Dao().FindRecordById("samples", sampleID)

	e := &Enricher{App: app}
	e.maybePropagateToFieldtrip(sample, `{"locality":"Würzburg"}`)

	ft2, _ := app.Dao().FindRecordById("fieldtrips", ftID)
	if got := ft2.GetString("title"); got != "Heidehöhe Würzburg" {
		t.Errorf("title = %q, want 'Heidehöhe Würzburg' (kein Overwrite)", got)
	}
}

func TestEnricher_RunSafely_RecoversFromDownstreamPanic(t *testing.T) {
	app := newAppForRecordsOnly(t)

	// Wir provozieren einen Panic, indem wir ein nicht-existentes
	// Sample ID übergeben — der nachfolgende Code würde sonst auf nil
	// dereferenzieren. Tatsächlich loggt run() nur und kehrt zurück,
	// also testen wir: runSafely darf keinen Panic durch die
	// Goroutine-Grenze lassen, selbst wenn run() einen produziert.
	//
	// Falls run() je doch direkt paniken sollte: dieser Test fängt es.
	e := &Enricher{App: app}

	// kein t.Fatal hier — wir wollen, dass die Funktion sauber
	// zurückkehrt, ohne den Test zu reißen.
	done := make(chan struct{})
	go func() {
		defer close(done)
		e.runSafely("does-not-exist", 0, 0, "")
	}()
	select {
	case <-done:
		// gut: kein Panic durchgereicht
	case <-time.After(5 * time.Second):
		t.Fatal("runSafely hat nicht innerhalb von 5s zurückgekehrt")
	}
}
