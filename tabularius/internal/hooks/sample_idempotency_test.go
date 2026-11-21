package hooks

import (
	"net/http"
	"strings"
	"testing"

	"go.mett.io/tabularius/internal/testutil"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func storedSample(t *testing.T, app *tests.TestApp, ownerID, clientUUID string) *core.Record {
	t.Helper()
	rec := newSampleRecord(t, app)
	rec.Set("owner", ownerID)
	rec.Set("client_uuid", clientUUID)
	rec.Set("sample_id", "260519/"+clientUUID)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save sample: %v", err)
	}
	return rec
}

// The app repeats a create after a timeout without knowing whether the
// first attempt arrived. The same client_uuid must find the sample that
// exists instead of creating it again under a suffixed id.
func TestExistingSample_SameOwnerAndUUID(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "idem1"+uniqueSuffix(t)+"@example.com")
	first := storedSample(t, app, owner.Id, "uuid-1")
	got := existingSample(app, owner.Id, "uuid-1")
	if got == nil || got.Id != first.Id {
		t.Fatalf("existing sample not found: %v", got)
	}
}

func TestExistingSample_OtherOwnerOrUUIDIsNoMatch(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "idem2"+uniqueSuffix(t)+"@example.com")
	other := createTestUser(t, app, "idem3"+uniqueSuffix(t)+"@example.com")
	storedSample(t, app, owner.Id, "uuid-1")
	if existingSample(app, other.Id, "uuid-1") != nil {
		t.Error("another owner's sample must not match")
	}
	if existingSample(app, owner.Id, "uuid-2") != nil {
		t.Error("another client_uuid must not match")
	}
}

func TestExistingSample_EmptyUUIDOrOwnerNeverMatches(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "idem4"+uniqueSuffix(t)+"@example.com")
	storedSample(t, app, owner.Id, "")
	if existingSample(app, owner.Id, "") != nil || existingSample(app, owner.Id, "  ") != nil {
		t.Error("an empty client_uuid must never match")
	}
	if existingSample(app, "", "uuid-1") != nil {
		t.Error("an empty owner must never match")
	}
}

func sampleCount(t testing.TB, app *tests.TestApp, ownerID string) int {
	t.Helper()
	var n int
	if err := app.DB().NewQuery(`SELECT COUNT(*) FROM samples WHERE owner = {:o}`).
		Bind(map[string]any{"o": ownerID}).Row(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func createSampleScenario(app *tests.TestApp, token, body string, after func(t testing.TB, res *http.Response)) tests.ApiScenario {
	return tests.ApiScenario{
		Method:         http.MethodPost,
		URL:            "/api/collections/samples/records",
		Body:           strings.NewReader(body),
		Headers:        map[string]string{"Authorization": token, "Content-Type": "application/json"},
		ExpectedStatus: http.StatusOK,
		TestAppFactory: func(testing.TB) *tests.TestApp { return app },
		// The test owns the app.
		DisableTestAppCleanup: true,
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, _ *core.ServeEvent) {
			RegisterSampleCreate(app)
		},
		AfterTestFunc: func(t testing.TB, _ *tests.TestApp, res *http.Response) {
			after(t, res)
		},
	}
}

const sampleCreateBody = `{"client_uuid":"uuid-1","sample_id":"260519/7","begin_date":"2026-05-19 12:00:00.000Z"}`

// Over HTTP: the repeated create answers with the stored sample, marks
// the answer as a replay and stores nothing — no second row, no
// " (2)" suffix.
func TestSampleCreate_RepeatAnswersWithExistingSample(t *testing.T) {
	app := testutil.NewTestApp(t)
	owner := createTestUser(t, app, "idem5"+uniqueSuffix(t)+"@example.com")
	first := storedSample(t, app, owner.Id, "uuid-1")
	tok, err := owner.NewAuthToken()
	if err != nil {
		t.Fatal(err)
	}
	sc := createSampleScenario(app, tok, sampleCreateBody, func(t testing.TB, res *http.Response) {
		if got := res.Header.Get(replayHeader); got != "true" {
			t.Errorf("%s = %q, want true", replayHeader, got)
		}
		if n := sampleCount(t, app, owner.Id); n != 1 {
			t.Errorf("samples = %d, want 1", n)
		}
		// Answered before the grouping ran: the replay creates or
		// extends no fieldtrip.
		var trips int
		if err := app.DB().NewQuery(`SELECT COUNT(*) FROM fieldtrips WHERE owner = {:o}`).
			Bind(map[string]any{"o": owner.Id}).Row(&trips); err != nil {
			t.Fatal(err)
		}
		if trips != 0 {
			t.Errorf("fieldtrips = %d, want 0", trips)
		}
	})
	sc.Name = "repeat"
	sc.ExpectedContent = []string{`"id":"` + first.Id + `"`, `"sample_id":"260519/uuid-1"`}
	sc.Test(t)
}

// A first create is stored as before and is no replay.
func TestSampleCreate_FirstCreateIsNoReplay(t *testing.T) {
	app := testutil.NewTestApp(t)
	owner := createTestUser(t, app, "idem6"+uniqueSuffix(t)+"@example.com")
	other := createTestUser(t, app, "idem7"+uniqueSuffix(t)+"@example.com")
	// Another owner's sample with the same uuid is no match.
	storedSample(t, app, other.Id, "uuid-1")
	tok, err := owner.NewAuthToken()
	if err != nil {
		t.Fatal(err)
	}
	sc := createSampleScenario(app, tok, sampleCreateBody, func(t testing.TB, res *http.Response) {
		if got := res.Header.Get(replayHeader); got != "" {
			t.Errorf("%s = %q on a first create", replayHeader, got)
		}
		if n := sampleCount(t, app, owner.Id); n != 1 {
			t.Errorf("samples = %d, want 1", n)
		}
	})
	sc.Name = "first"
	sc.ExpectedContent = []string{`"sample_id":"260519/7"`, `"client_uuid":"uuid-1"`}
	sc.Test(t)
}
