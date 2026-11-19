package migrations

import (
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

func photoFileMaxSize(t *testing.T, app core.App) int64 {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		t.Fatal(err)
	}
	f, ok := coll.Fields.GetByName("photo_file").(*core.FileField)
	if !ok {
		t.Fatal("photo_file is not a file field")
	}
	return f.MaxSize
}

func TestPhaseSPhotoLimit(t *testing.T) {
	app := setupTestApp(t)
	if got := photoFileMaxSize(t, app); got != 50*1024*1024 {
		t.Errorf("max size = %d, want 50 MB", got)
	}
	if err := phaseSPhotoLimitDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	if got := photoFileMaxSize(t, app); got != 10*1024*1024 {
		t.Errorf("max size after down = %d, want 10 MB", got)
	}
}

func photoUUIDIndex(t *testing.T, app core.App) bool {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		t.Fatal(err)
	}
	for _, idx := range coll.Indexes {
		if strings.Contains(idx, phaseSPhotoUUIDIndex) && strings.Contains(strings.ToUpper(idx), "UNIQUE") {
			return true
		}
	}
	return false
}

func insertPhotoRow(t *testing.T, app core.App, id, owner, uuid string) error {
	t.Helper()
	_, err := app.DB().NewQuery(`INSERT INTO sample_photos (id, owner, client_uuid) VALUES ({:id}, {:o}, {:u})`).
		Bind(map[string]any{"id": id, "o": owner, "u": uuid}).Execute()
	return err
}

// The index is what makes a concurrent retry safe: the second insert of
// the same (owner, client_uuid) fails instead of storing a duplicate.
func TestPhaseSPhotoUUIDIsUniquePerOwner(t *testing.T) {
	app := setupTestApp(t)
	if !photoUUIDIndex(t, app) {
		t.Fatal("unique index missing")
	}
	if err := insertPhotoRow(t, app, "pht000000000001", "owner1", "uuid-1"); err != nil {
		t.Fatal(err)
	}
	if err := insertPhotoRow(t, app, "pht000000000002", "owner1", "uuid-1"); err == nil {
		t.Error("second row with the same owner and client_uuid was accepted")
	}
	if err := insertPhotoRow(t, app, "pht000000000003", "owner2", "uuid-1"); err != nil {
		t.Errorf("another owner must be free to use the uuid: %v", err)
	}
	// Photos without a uuid (old clients) are never unique.
	for _, id := range []string{"pht000000000004", "pht000000000005"} {
		if err := insertPhotoRow(t, app, id, "owner1", ""); err != nil {
			t.Errorf("empty uuid rejected: %v", err)
		}
	}
}

// Duplicates from before the index keep their files: the later rows
// lose their uuid, so the index can be created and nothing is deleted.
func TestPhaseSPhotoLimit_KeepsExistingDuplicates(t *testing.T) {
	app := setupTestApp(t)
	if err := phaseSPhotoLimitDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	for _, id := range []string{"pht000000000001", "pht000000000002", "pht000000000003"} {
		if err := insertPhotoRow(t, app, id, "owner1", "uuid-1"); err != nil {
			t.Fatal(err)
		}
	}
	if err := phaseSPhotoLimitUp(app); err != nil {
		t.Fatalf("up with duplicates: %v", err)
	}
	var total, withUUID int
	if err := app.DB().NewQuery(`SELECT COUNT(*) FROM sample_photos`).Row(&total); err != nil {
		t.Fatal(err)
	}
	if err := app.DB().NewQuery(`SELECT COUNT(*) FROM sample_photos WHERE client_uuid = 'uuid-1'`).Row(&withUUID); err != nil {
		t.Fatal(err)
	}
	if total != 3 || withUUID != 1 {
		t.Errorf("rows = %d, with the uuid = %d; want 3 and 1", total, withUUID)
	}
	if !photoUUIDIndex(t, app) {
		t.Error("unique index missing after up")
	}
}
