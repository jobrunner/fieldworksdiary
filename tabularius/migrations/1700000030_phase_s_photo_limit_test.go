package migrations

import (
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
