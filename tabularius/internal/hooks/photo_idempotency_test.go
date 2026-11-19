package hooks

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func storedPhoto(t *testing.T, app *tests.TestApp, ownerID, clientUUID string) *core.Record {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		t.Fatal(err)
	}
	rec := core.NewRecord(coll)
	rec.Set("owner", ownerID)
	rec.Set("client_uuid", clientUUID)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("save photo: %v", err)
	}
	return rec
}

// A repeated upload (timeout, retry) carries the same client_uuid and
// must find the photo that already exists.
func TestExistingPhoto_SameOwnerAndUUID(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "photo1"+uniqueSuffix(t)+"@example.com")
	first := storedPhoto(t, app, owner.Id, "uuid-1")
	got := existingPhoto(app, owner.Id, "uuid-1")
	if got == nil || got.Id != first.Id {
		t.Fatalf("existing photo not found: %v", got)
	}
}

func TestExistingPhoto_OtherOwnerOrUUIDIsNoMatch(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "photo2"+uniqueSuffix(t)+"@example.com")
	other := createTestUser(t, app, "photo3"+uniqueSuffix(t)+"@example.com")
	storedPhoto(t, app, owner.Id, "uuid-1")
	if existingPhoto(app, other.Id, "uuid-1") != nil {
		t.Error("another owner's photo must not match")
	}
	if existingPhoto(app, owner.Id, "uuid-2") != nil {
		t.Error("another client_uuid must not match")
	}
}

// Photos without a client_uuid (old clients) are never merged.
func TestExistingPhoto_EmptyUUIDNeverMatches(t *testing.T) {
	app := setupTestApp(t)
	owner := createTestUser(t, app, "photo4"+uniqueSuffix(t)+"@example.com")
	storedPhoto(t, app, owner.Id, "")
	if existingPhoto(app, owner.Id, "") != nil || existingPhoto(app, owner.Id, "  ") != nil {
		t.Error("an empty client_uuid must never match")
	}
	if existingPhoto(app, "", "uuid-1") != nil {
		t.Error("an empty owner must never match")
	}
}
