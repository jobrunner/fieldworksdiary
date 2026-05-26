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
// Feldern lat/lon. Die anderen Felder werden im Test gezielt gesetzt.
func newSampleRecord(t *testing.T, app *tests.TestApp) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatalf("samples collection: %v", err)
	}
	rec := models.NewRecord(coll)
	rec.Set("lat", 49.793)
	rec.Set("lon", 9.939)
	return rec
}

// uniqueSuffix produziert pro Test-Aufruf einen eindeutigen Username-
// Anhang, weil `users.username` global eindeutig ist.
func uniqueSuffix(t *testing.T) string {
	t.Helper()
	return strings.ReplaceAll(t.Name(), "/", "_")
}

// ────────────────────────────────────────────────────────────────────
// processSample — Code-Vergabe + Fieldtrip + Sequence
// ────────────────────────────────────────────────────────────────────

func TestProcessSample_AssignsFreshCodeForFirstSampleOfDay(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "ada@example.com")

	rec := newSampleRecord(t, app)
	rec.Set("collected_from", time.Date(2026, 5, 19, 14, 0, 0, 0, berlin))

	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}

	if got := rec.GetString("code"); got != "260519/1" {
		t.Errorf("code = %q, want 260519/1", got)
	}
	if got := rec.GetString("owner"); got != owner.Id {
		t.Errorf("owner = %q, want %q", got, owner.Id)
	}
	if rec.GetString("fieldtrip") == "" {
		t.Error("fieldtrip not set")
	}
}

func TestProcessSample_IncrementsSequenceForSecondSampleSameDay(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "bea@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	first := newSampleRecord(t, app)
	first.Set("collected_from", day)
	if err := processSample(app.Dao(), first, owner.Id); err != nil {
		t.Fatalf("first: %v", err)
	}
	if err := app.Dao().SaveRecord(first); err != nil {
		t.Fatalf("save first: %v", err)
	}

	second := newSampleRecord(t, app)
	second.Set("collected_from", day.Add(2*time.Hour))
	if err := processSample(app.Dao(), second, owner.Id); err != nil {
		t.Fatalf("second: %v", err)
	}

	if got := second.GetString("code"); got != "260519/2" {
		t.Errorf("second code = %q, want 260519/2", got)
	}
	if first.GetString("fieldtrip") != second.GetString("fieldtrip") {
		t.Errorf("fieldtrip mismatch: first=%q second=%q",
			first.GetString("fieldtrip"), second.GetString("fieldtrip"))
	}
}

func TestProcessSample_DifferentOwnersGetSeparateFieldtripsAndSequences(t *testing.T) {
	app := setupTestApp(t)
	alice := createTestUser(t, app, "alice@example.com")
	bob := createTestUser(t, app, "bob@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	aliceSample := newSampleRecord(t, app)
	aliceSample.Set("collected_from", day)
	if err := processSample(app.Dao(), aliceSample, alice.Id); err != nil {
		t.Fatalf("alice: %v", err)
	}

	bobSample := newSampleRecord(t, app)
	bobSample.Set("collected_from", day)
	if err := processSample(app.Dao(), bobSample, bob.Id); err != nil {
		t.Fatalf("bob: %v", err)
	}

	// Beide bekommen Sequence 1 — Counter ist pro (owner, day).
	if got := aliceSample.GetString("code"); got != "260519/1" {
		t.Errorf("alice code = %q, want 260519/1", got)
	}
	if got := bobSample.GetString("code"); got != "260519/1" {
		t.Errorf("bob code = %q, want 260519/1", got)
	}
	// Aber unterschiedliche Fieldtrips.
	if aliceSample.GetString("fieldtrip") == bobSample.GetString("fieldtrip") {
		t.Errorf("alice und bob teilen sich eine Fieldtrip: %q",
			aliceSample.GetString("fieldtrip"))
	}
}

func TestProcessSample_DefaultsCollectedFromToNowWhenZero(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "carla@example.com")

	rec := newSampleRecord(t, app)
	// collected_from bewusst nicht gesetzt → Zero-Value.

	before := time.Now()
	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}
	after := time.Now()

	got := rec.GetDateTime("collected_from").Time()
	if got.Before(before) || got.After(after.Add(time.Second)) {
		t.Errorf("collected_from = %v, expected between %v and %v", got, before, after)
	}
}

func TestProcessSample_RespectsTagesrolloverBeforeCutoff(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "dora@example.com")

	// 19.05.2026 um 03:00 Uhr Berlin liegt VOR dem 5-Uhr-Cutoff →
	// gehört noch zum Sammeltag des 18.05.
	rec := newSampleRecord(t, app)
	rec.Set("collected_from", time.Date(2026, 5, 19, 3, 0, 0, 0, berlin))

	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}

	if got := rec.GetString("code"); got != "260518/1" {
		t.Errorf("code = %q, want 260518/1 (vor Cutoff = Vortag)", got)
	}
}

func TestProcessSample_HonorsClientCodeWithoutConflict(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "erik@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	rec := newSampleRecord(t, app)
	rec.Set("collected_from", day)
	rec.Set("code", "260519/7") // Offline-vergebener Code

	if err := processSample(app.Dao(), rec, owner.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}

	if got := rec.GetString("code"); got != "260519/7" {
		t.Errorf("code = %q, want 260519/7 (Client-Code honoriert)", got)
	}
	if got := rec.GetString("original_code"); got != "" {
		t.Errorf("original_code = %q, want empty (kein Reassignment)", got)
	}

	// Sequence muss auf 7 gesetzt worden sein — nächstes Sample soll 8 sein.
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save: %v", err)
	}
	next := newSampleRecord(t, app)
	next.Set("collected_from", day)
	if err := processSample(app.Dao(), next, owner.Id); err != nil {
		t.Fatalf("next: %v", err)
	}
	if got := next.GetString("code"); got != "260519/8" {
		t.Errorf("next code = %q, want 260519/8 (Sequenz war nach 7 hochgezogen)", got)
	}
}

func TestProcessSample_ReassignsCodeOnConflict(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "frida@example.com")
	day := time.Date(2026, 5, 19, 14, 0, 0, 0, berlin)

	// Vorbelegung: ein Sample mit Code 260519/3 existiert bereits.
	existing := newSampleRecord(t, app)
	existing.Set("collected_from", day)
	if err := processSample(app.Dao(), existing, owner.Id); err != nil {
		t.Fatalf("seed processSample: %v", err)
	}
	// Forciere den Code auf /3 (statt /1) für den Conflict-Test.
	existing.Set("code", "260519/3")
	if err := app.Dao().SaveRecord(existing); err != nil {
		t.Fatalf("save existing: %v", err)
	}

	// Zweiter User pusht denselben Code (z. B. Multi-Device-Offline).
	other := createTestUser(t, app, "george@example.com")
	rec := newSampleRecord(t, app)
	rec.Set("collected_from", day)
	rec.Set("code", "260519/3")

	if err := processSample(app.Dao(), rec, other.Id); err != nil {
		t.Fatalf("processSample: %v", err)
	}

	if got := rec.GetString("code"); got == "260519/3" {
		t.Errorf("code = %q, expected Reassignment", got)
	}
	if got := rec.GetString("original_code"); got != "260519/3" {
		t.Errorf("original_code = %q, want 260519/3 (Audit-Trail)", got)
	}
}

// ────────────────────────────────────────────────────────────────────
// ensureSequenceAtLeast — Idempotenz + Raise-Logik
// ────────────────────────────────────────────────────────────────────

func TestEnsureSequenceAtLeast_CreatesRowWhenMissing(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "hank@example.com")

	if err := ensureSequenceAtLeast(app.Dao(), owner.Id, "2026-05-19", 5); err != nil {
		t.Fatalf("ensureSequenceAtLeast: %v", err)
	}

	// Nächste Aufruf von nextSequence muss 6 zurückgeben.
	n, err := nextSequence(app.Dao(), owner.Id, "2026-05-19")
	if err != nil {
		t.Fatalf("nextSequence: %v", err)
	}
	if n != 6 {
		t.Errorf("nextSequence = %d, want 6", n)
	}
}

func TestEnsureSequenceAtLeast_RaisesWhenLower(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "ina@example.com")
	dayStr := "2026-05-19"

	// Counter zunächst auf 2 setzen via nextSequence.
	for i := 0; i < 2; i++ {
		if _, err := nextSequence(app.Dao(), owner.Id, dayStr); err != nil {
			t.Fatalf("seed nextSequence: %v", err)
		}
	}

	if err := ensureSequenceAtLeast(app.Dao(), owner.Id, dayStr, 10); err != nil {
		t.Fatalf("ensureSequenceAtLeast: %v", err)
	}

	n, err := nextSequence(app.Dao(), owner.Id, dayStr)
	if err != nil {
		t.Fatalf("nextSequence: %v", err)
	}
	if n != 11 {
		t.Errorf("nextSequence = %d, want 11", n)
	}
}

func TestEnsureSequenceAtLeast_NoOpWhenHigher(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "jana@example.com")
	dayStr := "2026-05-19"

	// Counter auf 5 hochziehen.
	for i := 0; i < 5; i++ {
		if _, err := nextSequence(app.Dao(), owner.Id, dayStr); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	// EnsureAtLeast mit kleinerem Wert darf nicht senken.
	if err := ensureSequenceAtLeast(app.Dao(), owner.Id, dayStr, 2); err != nil {
		t.Fatalf("ensureSequenceAtLeast: %v", err)
	}

	n, err := nextSequence(app.Dao(), owner.Id, dayStr)
	if err != nil {
		t.Fatalf("nextSequence: %v", err)
	}
	if n != 6 {
		t.Errorf("nextSequence = %d, want 6 (Counter blieb auf 5)", n)
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
	rec.Set("started_at", time.Date(2026, 5, 19, 22, 0, 0, 0, time.UTC))
	rec.Set("ended_at", time.Date(2026, 5, 19, 23, 30, 0, 0, time.UTC))

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
	if got := rec.GetString("name"); got != "Sammeltag 19.05.2026" {
		t.Errorf("name (empty case) = %q, want 'Sammeltag 19.05.2026'", got)
	}

	// User-vergebener Name → bleibt erhalten
	rec2 := models.NewRecord(coll)
	rec2.Set("name", "Heidehöhe")
	writeFieldtrip(rec2, &grouping.Fieldtrip{
		UserID: "user-id",
		Day:    time.Date(2026, 5, 19, 0, 0, 0, 0, berlin),
	})
	if got := rec2.GetString("name"); got != "Heidehöhe" {
		t.Errorf("name (user-set case) = %q, want Heidehöhe (kein Overwrite)", got)
	}
}
