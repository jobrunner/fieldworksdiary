// Package testutil provides a fast PocketBase test app for our tests.
//
// tests.NewTestApp() clones PocketBase's fixture database and runs all
// system and app migrations on every call. With PocketBase 0.23+ every
// collection save rebuilds the table in SQLite; under `go test -race`
// (pure-Go SQLite) that costs ~15 s per app, which pushes packages past
// the 10 min test timeout. NewTestApp migrates once per test binary and
// clones that migrated template for every test instead; the migrations
// themselves still run (and are tested) on the first call.
//
// The caller's package must register the app migrations (blank import of
// go.mett.io/fwd-backend/migrations, or being that package).
package testutil

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/tests"
)

const templatePrefix = "fwd_testapp_template_"

var (
	once        sync.Once
	templateDir string
	templateErr error
)

// NewTestApp returns a migrated test app that is cleaned up with the test.
func NewTestApp(tb testing.TB) *tests.TestApp {
	tb.Helper()
	once.Do(buildTemplate)
	if templateErr != nil {
		tb.Fatalf("test-app template: %v", templateErr)
	}
	app, err := tests.NewTestApp(templateDir)
	if err != nil {
		tb.Fatalf("test-app: %v", err)
	}
	tb.Cleanup(app.Cleanup)
	return app
}

func buildTemplate() {
	removeStaleTemplates()
	app, err := tests.NewTestApp()
	if err != nil {
		templateErr = err
		return
	}
	defer app.Cleanup()
	// Flush the WAL so the copied data.db is complete.
	for _, db := range []func() error{
		func() error { _, err := app.DB().NewQuery("PRAGMA wal_checkpoint(TRUNCATE)").Execute(); return err },
		func() error { _, err := app.AuxDB().NewQuery("PRAGMA wal_checkpoint(TRUNCATE)").Execute(); return err },
	} {
		if err := db(); err != nil {
			templateErr = err
			return
		}
	}
	dir, err := tests.TempDirClone(app.DataDir())
	if err != nil {
		templateErr = err
		return
	}
	// Rename into a recognizable name so stale templates of crashed or
	// earlier runs can be swept.
	named := filepath.Join(filepath.Dir(dir), templatePrefix+filepath.Base(dir))
	if err := os.Rename(dir, named); err != nil {
		templateDir = dir
		return
	}
	templateDir = named
}

// removeStaleTemplates deletes templates older than an hour (a test
// binary has no exit hook to remove its own).
func removeStaleTemplates() {
	entries, err := os.ReadDir(os.TempDir())
	if err != nil {
		return
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), templatePrefix) {
			continue
		}
		if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > time.Hour {
			_ = os.RemoveAll(filepath.Join(os.TempDir(), e.Name()))
		}
	}
}
