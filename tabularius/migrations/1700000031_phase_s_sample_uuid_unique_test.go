package migrations

import (
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

func sampleUUIDIndex(t *testing.T, app core.App) bool {
	t.Helper()
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatal(err)
	}
	for _, idx := range coll.Indexes {
		if strings.Contains(idx, sampleUUIDIndexName) && strings.Contains(strings.ToUpper(idx), "UNIQUE") {
			return true
		}
	}
	return false
}

func insertSampleRow(t *testing.T, app core.App, id, owner, uuid string) error {
	t.Helper()
	_, err := app.DB().NewQuery(`INSERT INTO samples (id, owner, client_uuid, sample_id) VALUES ({:id}, {:o}, {:u}, {:id})`).
		Bind(map[string]any{"id": id, "o": owner, "u": uuid}).Execute()
	return err
}

// The index is what makes a repeated create safe: the second insert of
// the same (owner, client_uuid) fails instead of storing the sample
// twice — also when the first request is still running.
func TestSampleUUIDIsUniquePerOwner(t *testing.T) {
	app := setupTestApp(t)
	if !sampleUUIDIndex(t, app) {
		t.Fatal("unique index missing")
	}
	if err := insertSampleRow(t, app, "smu000000000001", "owner1", "uuid-1"); err != nil {
		t.Fatal(err)
	}
	if err := insertSampleRow(t, app, "smu000000000002", "owner1", "uuid-1"); err == nil {
		t.Error("second sample with the same owner and client_uuid was accepted")
	}
	if err := insertSampleRow(t, app, "smu000000000003", "owner2", "uuid-1"); err != nil {
		t.Errorf("another owner must be free to use the uuid: %v", err)
	}
	for _, id := range []string{"smu000000000004", "smu000000000005"} {
		if err := insertSampleRow(t, app, id, "owner1", ""); err != nil {
			t.Errorf("empty uuid rejected: %v", err)
		}
	}
}

// Duplicates that exist already are kept: they are real rows the user
// may have edited. Only the later ones lose their uuid, so the index can
// be created; nothing is deleted or merged.
func TestSampleUUIDUnique_KeepsExistingDuplicates(t *testing.T) {
	app := setupTestApp(t)
	if err := sampleUUIDUniqueDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	for _, id := range []string{"smu000000000001", "smu000000000002", "smu000000000003"} {
		if err := insertSampleRow(t, app, id, "owner1", "uuid-1"); err != nil {
			t.Fatal(err)
		}
	}
	if err := sampleUUIDUniqueUp(app); err != nil {
		t.Fatalf("up with duplicates: %v", err)
	}
	var total, withUUID int
	if err := app.DB().NewQuery(`SELECT COUNT(*) FROM samples`).Row(&total); err != nil {
		t.Fatal(err)
	}
	if err := app.DB().NewQuery(`SELECT COUNT(*) FROM samples WHERE client_uuid = 'uuid-1'`).Row(&withUUID); err != nil {
		t.Fatal(err)
	}
	if total != 3 || withUUID != 1 {
		t.Errorf("rows = %d, with the uuid = %d; want 3 and 1", total, withUUID)
	}
	var keeper string
	if err := app.DB().NewQuery(`SELECT id FROM samples WHERE client_uuid = 'uuid-1'`).Row(&keeper); err != nil {
		t.Fatal(err)
	}
	if keeper != "smu000000000001" {
		t.Errorf("uuid stayed with %s, want the oldest row", keeper)
	}
	if !sampleUUIDIndex(t, app) {
		t.Error("unique index missing after up")
	}
}

func TestSampleUUIDUnique_DownRemovesIndex(t *testing.T) {
	app := setupTestApp(t)
	if err := sampleUUIDUniqueDown(app); err != nil {
		t.Fatalf("down: %v", err)
	}
	if sampleUUIDIndex(t, app) {
		t.Error("index still present after down")
	}
}
