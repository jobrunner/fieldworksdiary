package hooks

import (
	"errors"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"
)

// Helper: build a *core.Record whose "original" snapshot has the
// given version, and whose pending state matches `incoming`. We mimic
// what PocketBase does during an update: the record is loaded from
// disk, the user-supplied payload is layered on top, and the hook
// runs before `dao.SaveRecord` actually writes it back.
func recordWithVersion(t *testing.T, current, incoming int) *core.Record {
	t.Helper()
	app := setupTestApp(t)
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatalf("samples collection: %v", err)
	}
	rec := core.NewRecord(coll)
	rec.Set("version", current)
	// "Save" the baseline so OriginalCopy() reflects `current`.
	rec.MarkAsNew()
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("seed save: %v", err)
	}
	// Reload so the pristine copy lives inside OriginalCopy().
	reloaded, err := app.FindRecordById("samples", rec.Id)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	// Now layer the incoming payload on top.
	reloaded.Set("version", incoming)
	return reloaded
}

func TestEnforceVersion_AcceptsFreshIncrement(t *testing.T) {
	rec := recordWithVersion(t, 3, 4)
	if err := enforceVersion(rec); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := rec.GetInt("version"); got != 4 {
		t.Errorf("version after hook = %d, want 4 (current+1)", got)
	}
}

func TestEnforceVersion_AcceptsLegacyZero(t *testing.T) {
	// Client that pre-dates the version concept — sends version=0
	// (or omits it). Server accepts and assigns the next counter.
	rec := recordWithVersion(t, 7, 0)
	if err := enforceVersion(rec); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := rec.GetInt("version"); got != 8 {
		t.Errorf("version after hook = %d, want 8 (current+1)", got)
	}
}

func TestEnforceVersion_RejectsStaleEqualVersion(t *testing.T) {
	rec := recordWithVersion(t, 3, 3)
	err := enforceVersion(rec)
	if err == nil {
		t.Fatal("expected 409, got nil")
	}
	var apiErr *router.ApiError
	if !errors.As(err, &apiErr) || apiErr.Status != 409 {
		t.Errorf("expected 409 ApiError, got %T %v", err, err)
	}
}

func TestEnforceVersion_RejectsStaleLowerVersion(t *testing.T) {
	rec := recordWithVersion(t, 5, 2)
	err := enforceVersion(rec)
	if err == nil {
		t.Fatal("expected 409, got nil")
	}
	var apiErr *router.ApiError
	if !errors.As(err, &apiErr) || apiErr.Status != 409 {
		t.Errorf("expected 409 ApiError, got %T %v", err, err)
	}
}

func TestEnforceVersion_NormalizesAheadOfClient(t *testing.T) {
	// Client sent version=12 but the server is still at 4; the
	// canonical next-version is 5, not 12 — the response must
	// carry 5 so the next push uses 6.
	rec := recordWithVersion(t, 4, 12)
	if err := enforceVersion(rec); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := rec.GetInt("version"); got != 5 {
		t.Errorf("version after hook = %d, want 5 (server-canonical current+1)", got)
	}
}
