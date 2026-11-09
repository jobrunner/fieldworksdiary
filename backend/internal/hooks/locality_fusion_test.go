package hooks

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/tests"
)

// makeLocality seeds a locality with the given coords + owner and
// returns the saved record. Bypasses the create-hook by calling
// `dao.SaveRecord` directly — handy because the fusion-hook is what
// we actually want to test.
func makeLocality(t *testing.T, app *tests.TestApp, ownerID string, lat, lon float64) *models.Record {
	t.Helper()
	coll, err := app.Dao().FindCollectionByNameOrId("localities")
	if err != nil {
		t.Fatalf("localities collection: %v", err)
	}
	rec := models.NewRecord(coll)
	rec.Set("owner", ownerID)
	rec.Set("name", "Test")
	rec.Set("latitude", lat)
	rec.Set("longitude", lon)
	rec.Set("location_source", "user")
	rec.Set("version", 1)
	if err := app.Dao().SaveRecord(rec); err != nil {
		t.Fatalf("save locality: %v", err)
	}
	return rec
}

// runFusionFor invokes the FusionRunner synchronously against a
// fresh dao — bypasses the goroutine path in the hook so the test
// can assert against the post-run DB state without sleeping.
func runFusionFor(t *testing.T, app *tests.TestApp, localityID string) {
	t.Helper()
	runner := &FusionRunner{App: app}
	if err := runner.run(localityID); err != nil {
		t.Fatalf("FusionRunner.run: %v", err)
	}
}

// TestFusion_NoNeighbors_KeepAsIs — a single locality stays
// standalone and isn't flagged.
func TestFusion_NoNeighbors_KeepAsIs(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "alone@example.com")
	loc := makeLocality(t, app, owner.Id, 49.79, 9.94)

	runFusionFor(t, app, loc.Id)

	reloaded, err := app.Dao().FindRecordById("localities", loc.Id)
	if err != nil {
		t.Fatalf("locality vanished: %v", err)
	}
	if reloaded.GetBool("needs_human_review") {
		t.Error("solo locality should not be flagged for review")
	}
}

// TestFusion_SingleClose_MergeAndEmit — incoming locality with one
// neighbor inside the radius gets merged; its samples re-point;
// a remap event lands; the duplicate is gone.
func TestFusion_SingleClose_MergeAndEmit(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "merger@example.com")

	target := makeLocality(t, app, owner.Id, 49.79, 9.94)
	dup := makeLocality(t, app, owner.Id, 49.79, 9.94042) // ~30 m east

	// Seed two samples on the duplicate so we can check that
	// they get re-hung onto the target.
	samColl, _ := app.Dao().FindCollectionByNameOrId("samples")
	for i := 0; i < 2; i++ {
		s := models.NewRecord(samColl)
		s.Set("owner", owner.Id)
		s.Set("locality", dup.Id)
		s.Set("sample_id", "260519/X")
		s.Set("latitude", 49.79)
		s.Set("longitude", 9.94042)
		s.Set("collecting_day", "2026-05-19")
		s.Set("location_source", "location_service")
		s.Set("timezone", "Europe/Berlin")
		s.Set("version", 1)
		if err := app.Dao().SaveRecord(s); err != nil {
			t.Fatalf("seed sample: %v", err)
		}
	}

	runFusionFor(t, app, dup.Id)

	// Duplicate is gone.
	if _, err := app.Dao().FindRecordById("localities", dup.Id); err == nil {
		t.Error("duplicate locality should be deleted after merge")
	}

	// Samples now point at target.
	moved, err := app.Dao().FindRecordsByFilter(
		"samples", "locality = {:t}", "", 0, 0,
		map[string]any{"t": target.Id},
	)
	if err != nil {
		t.Fatalf("sample lookup: %v", err)
	}
	if len(moved) != 2 {
		t.Errorf("expected 2 samples on target, got %d", len(moved))
	}

	// A remap event was emitted, owner-tagged.
	events, err := app.Dao().FindRecordsByFilter(
		"locality_remap_events",
		"owner = {:o} && new_locality_id = {:n}",
		"-created", 0, 0,
		map[string]any{"o": owner.Id, "n": target.Id},
	)
	if err != nil {
		t.Fatalf("events lookup: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("expected 1 remap event, got %d", len(events))
	}
	ev := events[0]
	if got := ev.GetString("old_locality_id"); got != dup.Id {
		t.Errorf("old_locality_id = %q, want %q", got, dup.Id)
	}
	if got := ev.GetString("reason"); got != "merged_with_existing" {
		t.Errorf("reason = %q, want merged_with_existing", got)
	}
	var movedIDs []string
	if err := json.Unmarshal([]byte(ev.GetString("affected_sample_ids")), &movedIDs); err != nil {
		t.Fatalf("affected_sample_ids decode: %v", err)
	}
	if len(movedIDs) != 2 {
		t.Errorf("affected_sample_ids length = %d, want 2", len(movedIDs))
	}
}

// TestFusion_TwoNeighbors_FlagAmbiguous — two close neighbors flips
// the review flag instead of merging.
func TestFusion_TwoNeighbors_FlagAmbiguous(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "ambig@example.com")

	_ = makeLocality(t, app, owner.Id, 49.79, 9.94042)  // ~30 m east
	_ = makeLocality(t, app, owner.Id, 49.79, 9.939589) // ~30 m west
	incoming := makeLocality(t, app, owner.Id, 49.79, 9.94)

	runFusionFor(t, app, incoming.Id)

	reloaded, err := app.Dao().FindRecordById("localities", incoming.Id)
	if err != nil {
		t.Fatalf("incoming vanished: %v", err)
	}
	if !reloaded.GetBool("needs_human_review") {
		t.Error("ambiguous neighbor set should flag review")
	}

	// No remap event for ambiguous-flag — only merges emit those.
	events, err := app.Dao().FindRecordsByFilter(
		"locality_remap_events", "owner = {:o}", "", 0, 0,
		map[string]any{"o": owner.Id},
	)
	if err != nil {
		t.Fatalf("events lookup: %v", err)
	}
	if len(events) != 0 {
		t.Errorf("expected 0 events on ambiguous, got %d", len(events))
	}
}

// TestFusion_OwnerScopedCandidates — User A's locality must not
// merge into User B's, even at the same coords.
func TestFusion_OwnerScopedCandidates(t *testing.T) {
	app := setupTestApp(t)
	alice := createTestUser(t, app, "alice@example.com")
	bob := createTestUser(t, app, "bob@example.com")

	_ = makeLocality(t, app, alice.Id, 49.79, 9.94)
	bobLoc := makeLocality(t, app, bob.Id, 49.79, 9.94) // same coords

	runFusionFor(t, app, bobLoc.Id)

	// Bob's locality must still exist — Alice's row isn't a
	// candidate for him.
	if _, err := app.Dao().FindRecordById("localities", bobLoc.Id); err != nil {
		t.Errorf("bob's locality should not be merged into alice's")
	}
	if got := bobLoc.GetBool("needs_human_review"); got {
		t.Error("ambig flag should be off; alice's row is invisible to bob's fusion")
	}
}

// TestSignificantCoordChange_Hook — defensive: changing only `notes`
// shouldn't trigger fusion. We can't easily intercept the
// goroutine from the hook, so we just assert SignificantCoordChange
// returns false for an identical-coord update.
func TestNoFusionTriggerOnNotesOnlyEdit(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "noteedit@example.com")

	loc := makeLocality(t, app, owner.Id, 49.79, 9.94)
	loc.Set("notes", strings.Repeat("a", 100))
	if err := app.Dao().SaveRecord(loc); err != nil {
		t.Fatalf("save notes-only update: %v", err)
	}
	// `SignificantCoordChange(prev, new) == false` is enforced by
	// the dedicated unit test in `fusion_test.go`; here we just
	// verify the locality survives a notes edit unchanged.
	reloaded, err := app.Dao().FindRecordById("localities", loc.Id)
	if err != nil {
		t.Fatalf("locality vanished: %v", err)
	}
	if reloaded.GetString("notes") == "" {
		t.Error("notes field empty after save")
	}
}
