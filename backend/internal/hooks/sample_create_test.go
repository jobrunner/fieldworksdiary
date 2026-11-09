package hooks

import (
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/grouping"
	// Side-effect-Import: registriert unsere Migrations global, damit
	// `tests.NewTestApp` sie auf der frischen Test-DB anwendet.
	_ "go.mett.io/fwd-backend/migrations"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// setupTestApp baut eine frische in-memory-Test-PocketBase mit unserem
// Collection-Schema (Migrations sind über den blank-Import oben global
// registriert).
func setupTestApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("test-app setup: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

// createTestUser legt einen verifizierten User in `users` an und gibt
// das Record zurück (für owner-Felder).
func createTestUser(t *testing.T, app *tests.TestApp, email string) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	rec := models.NewRecord(coll)
	if err := rec.SetEmail(email); err != nil {
		t.Fatalf("set email: %v", err)
	}
	username := strings.SplitN(email, "@", 2)[0]
	if err := rec.SetUsername(username + uniqueSuffix(t)); err != nil {
		t.Fatalf("set username: %v", err)
	}
	if err := rec.SetPassword("test1234password"); err != nil {
		t.Fatalf("set password: %v", err)
	}
	if err := rec.SetVerified(true); err != nil {
		t.Fatalf("set verified: %v", err)
	}
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return rec
}

// newSampleRecord baut ein unsaved samples-Record mit den Pflicht-
// Feldern latitude/longitude. Die anderen Felder werden im Test
// gezielt gesetzt.
func newSampleRecord(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatalf("samples collection: %v", err)
	}
	rec := models.NewRecord(coll)
	rec.Set("latitude", 49.793)
	rec.Set("longitude", 9.939)
	return rec
}

// uniqueSuffix produziert pro Test-Aufruf einen eindeutigen Username-
// Anhang, weil `users.username` global eindeutig ist.
func uniqueSuffix(t *testing.T) string {
	t.Helper()
	return strings.ReplaceAll(t.Name(), "/", "_")
}

// ────────────────────────────────────────────────────────────────────
// processSample — ID bleibt wie gesendet, Sammeltag, Fieldtrip
// ────────────────────────────────────────────────────────────────────

func mustTZ(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("tz %s: %v", name, err)
	}
	return loc
}

// createSample verarbeitet und speichert ein Sample.
func createSample(t *testing.T, app *tests.TestApp, ownerID string, set map[string]any) *models.Record {
	t.Helper()
	rec := newSampleRecord(t, app)
	if _, ok := set["begin_date"]; !ok {
		rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))
	}
	for k, v := range set {
		rec.Set(k, v)
	}
	if err := processSample(app.Dao(), rec, ownerID); err != nil {
		t.Fatalf("processSample: %v", err)
	}
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save: %v", err)
	}
	return rec
}

func fieldtripOf(t *testing.T, app *tests.TestApp, rec *models.Record) *models.Record {
	t.Helper()
	ft, err := app.Dao().FindRecordById("fieldtrips", rec.GetString("fieldtrip"))
	if err != nil {
		t.Fatalf("fieldtrip: %v", err)
	}
	return ft
}

func TestCreate_KeepsClientID(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "ada@example.com")

	rec := createSample(t, app, owner.Id, map[string]any{"sample_id": "JB-17"})
	if got := rec.GetString("sample_id"); got != "JB-17" {
		t.Errorf("sample_id = %q, want JB-17", got)
	}
	if got := rec.GetString("original_code"); got != "" {
		t.Errorf("original_code = %q, want empty", got)
	}
	if rec.GetString("owner") != owner.Id || rec.GetString("fieldtrip") == "" {
		t.Error("owner/fieldtrip not set")
	}
}

func TestCreate_EmptyIDStaysEmpty(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "bea@example.com")

	a := createSample(t, app, owner.Id, nil)
	b := createSample(t, app, owner.Id, map[string]any{"sample_id": "   "})
	for _, r := range []*models.Record{a, b} {
		if got := r.GetString("sample_id"); got != "" {
			t.Errorf("sample_id = %q, want empty", got)
		}
		if got := r.GetString("original_code"); got != "" {
			t.Errorf("original_code = %q, want empty", got)
		}
	}
}

func TestCreate_SuffixPerOwner(t *testing.T) {
	app := setupTestApp(t)
	a := createTestUser(t, app, "alice@example.com")
	b := createTestUser(t, app, "bob@example.com")

	first := createSample(t, app, a.Id, map[string]any{"sample_id": "250611/3"})
	second := createSample(t, app, a.Id, map[string]any{"sample_id": "250611/3"})
	third := createSample(t, app, a.Id, map[string]any{"sample_id": "250611/3"})
	other := createSample(t, app, b.Id, map[string]any{"sample_id": "250611/3"})

	if got := first.GetString("sample_id"); got != "250611/3" {
		t.Errorf("first = %q", got)
	}
	if got := second.GetString("sample_id"); got != "250611/3 (2)" {
		t.Errorf("second = %q, want '250611/3 (2)'", got)
	}
	if got := second.GetString("original_code"); got != "250611/3" {
		t.Errorf("second original_code = %q", got)
	}
	if got := third.GetString("sample_id"); got != "250611/3 (3)" {
		t.Errorf("third = %q, want '250611/3 (3)'", got)
	}
	if got := other.GetString("sample_id"); got != "250611/3" {
		t.Errorf("other owner = %q, want unchanged", got)
	}
	if got := other.GetString("original_code"); got != "" {
		t.Errorf("other original_code = %q, want empty", got)
	}
}

func TestCreate_UsesClientCollectingDay(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "cd@example.com")

	rec := createSample(t, app, owner.Id, map[string]any{
		"collecting_day": "2026-06-10",
		"begin_date":     time.Date(2026, 6, 11, 2, 0, 0, 0, time.UTC),
	})
	if got := fieldtripOf(t, app, rec).GetString("collecting_day"); got != "2026-06-10" {
		t.Errorf("fieldtrip day = %q, want 2026-06-10", got)
	}
}

func TestCreate_ComputesDayInSampleTimezone(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "tz@example.com")
	begin := time.Date(2026, 1, 15, 23, 50, 0, 0, time.UTC)

	canary := createSample(t, app, owner.Id, map[string]any{
		"timezone": "Atlantic/Canary", "begin_date": begin,
	})
	if got := canary.GetString("collecting_day"); got != "2026-01-15" {
		t.Errorf("canary collecting_day = %q, want 2026-01-15", got)
	}
	if got := fieldtripOf(t, app, canary).GetString("collecting_day"); got != "2026-01-15" {
		t.Errorf("canary fieldtrip day = %q", got)
	}

	ber := createSample(t, app, owner.Id, map[string]any{
		"timezone": "Europe/Berlin", "begin_date": begin,
	})
	if got := ber.GetString("collecting_day"); got != "2026-01-16" {
		t.Errorf("berlin collecting_day = %q, want 2026-01-16", got)
	}
	if got := fieldtripOf(t, app, ber).GetString("collecting_day"); got != "2026-01-16" {
		t.Errorf("berlin fieldtrip day = %q", got)
	}
}

func TestCreate_UserCutoffHour(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "cut@example.com")
	owner.Set("day_cutoff_hour", 5)
	if err := app.Dao().SaveRecord(owner); err != nil {
		t.Fatalf("save user: %v", err)
	}

	// 03:30 Berlin (CEST) liegt vor dem 5-Uhr-Rollover → Vortag.
	rec := createSample(t, app, owner.Id, map[string]any{
		"timezone":   "Europe/Berlin",
		"begin_date": time.Date(2026, 6, 11, 1, 30, 0, 0, time.UTC),
	})
	if got := rec.GetString("collecting_day"); got != "2026-06-10" {
		t.Errorf("collecting_day = %q, want 2026-06-10", got)
	}
}

func TestCreate_DefaultRolloverZero(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "def@example.com")

	rec := createSample(t, app, owner.Id, map[string]any{
		"begin_date": time.Date(2026, 5, 19, 3, 0, 0, 0, berlin),
	})
	if got := rec.GetString("collecting_day"); got != "2026-05-19" {
		t.Errorf("collecting_day = %q, want 2026-05-19 (Rollover 0)", got)
	}
}

func TestCreate_NewFieldtripTakesSampleTimezone(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "ft@example.com")

	rec := createSample(t, app, owner.Id, map[string]any{
		"timezone":   "Atlantic/Canary",
		"begin_date": time.Date(2026, 1, 15, 23, 50, 0, 0, time.UTC),
	})
	ft := fieldtripOf(t, app, rec)
	if got := ft.GetString("timezone"); got != "Atlantic/Canary" {
		t.Errorf("fieldtrip timezone = %q", got)
	}
	e := fieldtripFromRecord(ft)
	if e.StartedAt.Location().String() != "Atlantic/Canary" {
		t.Errorf("window location = %q, want Atlantic/Canary", e.StartedAt.Location())
	}
	if e.StartedAt.Hour() != 23 || e.StartedAt.Day() != 15 {
		t.Errorf("window start local = %v", e.StartedAt)
	}
}

func TestCreate_SameDaySamplesShareFieldtrip(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "same@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	a := createSample(t, app, owner.Id, map[string]any{"begin_date": day})
	b := createSample(t, app, owner.Id, map[string]any{"begin_date": day.Add(2 * time.Hour)})
	if a.GetString("fieldtrip") != b.GetString("fieldtrip") {
		t.Errorf("fieldtrip mismatch: %q vs %q", a.GetString("fieldtrip"), b.GetString("fieldtrip"))
	}
}

func TestCreate_DifferentOwnersGetSeparateFieldtrips(t *testing.T) {
	app := setupTestApp(t)
	alice := createTestUser(t, app, "alice2@example.com")
	bob := createTestUser(t, app, "bob2@example.com")

	a := createSample(t, app, alice.Id, nil)
	b := createSample(t, app, bob.Id, nil)
	if a.GetString("fieldtrip") == b.GetString("fieldtrip") {
		t.Errorf("alice und bob teilen sich eine Fieldtrip")
	}
}

func TestProcessSample_DefaultsCollectedFromToNowWhenZero(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "carla@example.com")

	rec := newSampleRecord(t, app)
	before := time.Now()
	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}
	after := time.Now()

	got := rec.GetDateTime("begin_date").Time()
	if got.Before(before) || got.After(after.Add(time.Second)) {
		t.Errorf("begin_date = %v, expected between %v and %v", got, before, after)
	}
}

func TestCollectingDayFor_FallsBackToBerlinOnBadTimezone(t *testing.T) {
	app := setupTestApp(t)
	rec := newSampleRecord(t, app)
	rec.Set("timezone", "Nowhere/Land")
	rec.Set("begin_date", time.Date(2026, 1, 15, 23, 50, 0, 0, time.UTC))
	day, loc := collectingDayFor(rec, 0)
	if loc.String() != "Europe/Berlin" || day.Format("2006-01-02") != "2026-01-16" {
		t.Errorf("got %v in %v", day, loc)
	}
}

func TestUniqueSampleID_ExcludesOwnRecord(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "uq@example.com")
	rec := createSample(t, app, owner.Id, map[string]any{"sample_id": "X1"})

	got, err := uniqueSampleID(app.Dao(), owner.Id, "X1", rec.Id)
	if err != nil || got != "X1" {
		t.Errorf("own id: got %q, %v", got, err)
	}
	got, err = uniqueSampleID(app.Dao(), owner.Id, "X1", "")
	if err != nil || got != "X1 (2)" {
		t.Errorf("foreign id: got %q, %v", got, err)
	}
	got, err = uniqueSampleID(app.Dao(), owner.Id, "", "")
	if err != nil || got != "" {
		t.Errorf("empty: got %q, %v", got, err)
	}
}

func TestUpdate_SuffixOnCollidingIDChange(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "upd@example.com")
	createSample(t, app, owner.Id, map[string]any{"sample_id": "A"})
	x := createSample(t, app, owner.Id, map[string]any{"sample_id": "B"})

	reload := func() *models.Record {
		r, err := app.Dao().FindRecordById("samples", x.Id)
		if err != nil {
			t.Fatalf("reload: %v", err)
		}
		return r
	}

	// Update ohne ID-Änderung: ID und original_code bleiben.
	r := reload()
	r.Set("notes", "geändert")
	if err := resolveSampleIDOnUpdate(app.Dao(), r); err != nil {
		t.Fatalf("update: %v", err)
	}
	if r.GetString("sample_id") != "B" || r.GetString("original_code") != "" {
		t.Errorf("unchanged: %q / %q", r.GetString("sample_id"), r.GetString("original_code"))
	}

	// Update auf eigene aktuelle ID: kein Suffix.
	r = reload()
	r.Set("sample_id", "B")
	if err := resolveSampleIDOnUpdate(app.Dao(), r); err != nil {
		t.Fatalf("update: %v", err)
	}
	if r.GetString("sample_id") != "B" {
		t.Errorf("own id: %q", r.GetString("sample_id"))
	}

	// Update auf vergebene ID: Suffix + original_code.
	r = reload()
	r.Set("sample_id", "A")
	if err := resolveSampleIDOnUpdate(app.Dao(), r); err != nil {
		t.Fatalf("update: %v", err)
	}
	if r.GetString("sample_id") != "A (2)" || r.GetString("original_code") != "A" {
		t.Errorf("colliding: %q / %q", r.GetString("sample_id"), r.GetString("original_code"))
	}
}

func TestUpdate_KeepsLocationServiceTimezoneAgainstDevice(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "tz@example.com")
	x := createSample(t, app, owner.Id, map[string]any{
		"sample_id": "T1", "timezone": "Atlantic/Canary", "timezone_source": "location_service",
	})
	reload := func() *models.Record {
		r, err := app.Dao().FindRecordById("samples", x.Id)
		if err != nil {
			t.Fatalf("reload: %v", err)
		}
		return r
	}

	// Device zone from a stale client is refused.
	r := reload()
	r.Set("timezone", "Europe/Berlin")
	r.Set("timezone_source", "device")
	keepStrongerTimezone(r)
	if r.GetString("timezone") != "Atlantic/Canary" || r.GetString("timezone_source") != "location_service" {
		t.Errorf("downgrade not refused: %q / %q", r.GetString("timezone"), r.GetString("timezone_source"))
	}

	// A manual choice is accepted.
	r = reload()
	r.Set("timezone", "Asia/Tokyo")
	r.Set("timezone_source", "manual")
	keepStrongerTimezone(r)
	if r.GetString("timezone") != "Asia/Tokyo" || r.GetString("timezone_source") != "manual" {
		t.Errorf("manual refused: %q / %q", r.GetString("timezone"), r.GetString("timezone_source"))
	}

	// A device row may still be changed to anything.
	d := createSample(t, app, owner.Id, map[string]any{
		"sample_id": "T2", "timezone": "Europe/Berlin", "timezone_source": "device",
	})
	d, _ = app.Dao().FindRecordById("samples", d.Id)
	d.Set("timezone", "Asia/Tokyo")
	d.Set("timezone_source", "device")
	keepStrongerTimezone(d)
	if d.GetString("timezone") != "Asia/Tokyo" {
		t.Errorf("device row changed back: %q", d.GetString("timezone"))
	}
}

// ────────────────────────────────────────────────────────────────────
// authOwnerID — defensive Auth-Extraktion
// ────────────────────────────────────────────────────────────────────

// fakeAuthCtx implementiert nur das Interface, das authOwnerID braucht
// (`Get(string) any`). Damit testen wir die Auth-Extraktion ohne echo.
type fakeAuthCtx struct {
	values map[string]any
}

func (f *fakeAuthCtx) Get(key string) any { return f.values[key] }

func TestAuthOwnerID_ExtractsFromAuthRecord(t *testing.T) {
	app := setupTestApp(t)
	user := createTestUser(t, app, "kim@example.com")

	ctx := &fakeAuthCtx{values: map[string]any{
		apis.ContextAuthRecordKey: user,
	}}
	id, err := authOwnerID(ctx)
	if err != nil {
		t.Fatalf("authOwnerID: %v", err)
	}
	if id != user.Id {
		t.Errorf("id = %q, want %q", id, user.Id)
	}
}

func TestAuthOwnerID_FailsWhenNoAuthRecord(t *testing.T) {
	ctx := &fakeAuthCtx{values: map[string]any{}}
	if _, err := authOwnerID(ctx); err == nil {
		t.Error("authOwnerID akzeptiert leeren Kontext, sollte aber 401 werfen")
	}
}

func TestAuthOwnerID_FailsWhenAuthRecordHasWrongType(t *testing.T) {
	ctx := &fakeAuthCtx{values: map[string]any{
		apis.ContextAuthRecordKey: "not-a-record",
	}}
	if _, err := authOwnerID(ctx); err == nil {
		t.Error("authOwnerID akzeptiert String statt *models.Record")
	}
}

// ────────────────────────────────────────────────────────────────────
// fieldtripFromRecord / writeFieldtrip — Round-Trip + TZ
// ────────────────────────────────────────────────────────────────────

func TestFieldtripFromRecord_ConvertsUTCInstantsToBerlin(t *testing.T) {
	app := setupTestApp(t)

	coll, err := app.Dao().FindCollectionByNameOrId("fieldtrips")
	if err != nil {
		t.Fatalf("fieldtrips collection: %v", err)
	}
	rec := models.NewRecord(coll)
	rec.Set("owner", "user-id")
	rec.Set("collecting_day", "2026-05-19")
	// 22:00 UTC am 19.05. = 00:00 Berlin am 20.05. (CEST = UTC+2)
	rec.Set("begin_date", time.Date(2026, 5, 19, 22, 0, 0, 0, time.UTC))
	rec.Set("end_date", time.Date(2026, 5, 19, 23, 30, 0, 0, time.UTC))

	e := fieldtripFromRecord(rec)
	if e.StartedAt.Location().String() != berlin.String() {
		t.Errorf("started_at location = %q, want Europe/Berlin", e.StartedAt.Location())
	}
	if hour := e.StartedAt.Hour(); hour != 0 {
		t.Errorf("started_at Berlin hour = %d, want 0 (= 22 UTC + 2)", hour)
	}
	if day := e.StartedAt.Day(); day != 20 {
		t.Errorf("started_at Berlin day = %d, want 20", day)
	}
}

func TestWriteFieldtrip_FillsDefaultNameOnlyWhenEmpty(t *testing.T) {
	app := setupTestApp(t)
	coll, _ := app.Dao().FindCollectionByNameOrId("fieldtrips")

	// Leerer Name → wird befüllt mit "Sammeltag DD.MM.YYYY"
	rec := models.NewRecord(coll)
	writeFieldtrip(rec, &grouping.Fieldtrip{
		UserID: "user-id",
		Day:    time.Date(2026, 5, 19, 0, 0, 0, 0, berlin),
	})
	if got := rec.GetString("title"); got != "Sammeltag 19.05.2026" {
		t.Errorf("title (empty case) = %q, want 'Sammeltag 19.05.2026'", got)
	}

	// User-vergebener Title → bleibt erhalten
	rec2 := models.NewRecord(coll)
	rec2.Set("title", "Heidehöhe")
	writeFieldtrip(rec2, &grouping.Fieldtrip{
		UserID: "user-id",
		Day:    time.Date(2026, 5, 19, 0, 0, 0, 0, berlin),
	})
	if got := rec2.GetString("title"); got != "Heidehöhe" {
		t.Errorf("title (user-set case) = %q, want Heidehöhe (kein Overwrite)", got)
	}
}

func TestProcessSample_DefaultsLocationStatusToPending(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "lsp@example.com")

	rec := newSampleRecord(t, app)
	rec.Set("begin_date", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))
	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}
	if got := rec.GetString("location_status"); got != "pending" {
		t.Errorf("location_status = %q, want pending", got)
	}

	rec2 := newSampleRecord(t, app)
	rec2.Set("begin_date", time.Date(2026, 5, 19, 15, 0, 0, 0, berlin))
	rec2.Set("location_status", "inherited")
	if err := processSample(app.Dao(), rec2, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}
	if got := rec2.GetString("location_status"); got != "inherited" {
		t.Errorf("location_status = %q, want client value inherited", got)
	}
}

func TestProcessSample_ClientElevationGetsLocationServiceSource(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "elev@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	cases := []struct {
		name       string
		elevation  float64
		source     string
		wantSource string
	}{
		{"client height without source", 312.5, "", "location_service"},
		{"client height with manual source", 312.5, "manual", "manual"},
		{"no height", 0, "", ""},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := newSampleRecord(t, app)
			rec.Set("begin_date", day.Add(time.Duration(i)*time.Minute))
			rec.Set("elevation", c.elevation)
			rec.Set("elevation_source", c.source)
			if err := processSample(app.Dao(), rec, owner.Id); err != nil {
				t.Fatalf("processSample: %v", err)
			}
			if got := rec.GetString("elevation_source"); got != c.wantSource {
				t.Errorf("elevation_source = %q, want %q", got, c.wantSource)
			}
		})
	}
}
