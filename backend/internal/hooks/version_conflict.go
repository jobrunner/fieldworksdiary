// Phase R5.1 — optimistic-concurrency guard via the monotone
// `version` column we added in R3.
//
// On every record-update for a versioned collection we compare the
// incoming `version` against the one PocketBase already has on disk:
//
//   - `incoming == 0`  → legacy client without version awareness.
//     Accept, server takes ownership of the bump.
//   - `incoming <= current` → stale write. Return 409 so the iOS
//     SyncRunner pulls the fresh row and reconciles.
//   - `incoming > current` → fresh write. Server overwrites
//     `version` with `current + 1` regardless of how high the
//     client went; the response carries the canonical post-write
//     counter back, which the client must adopt.
//
// The server is intentionally the only place that *assigns* the
// next version. That way two devices that both bumped to
// `current + 1` still only one of them lands (the other gets 409),
// and the canonical sequence stays monotone.
package hooks

import (
	"net/http"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
)

// versionedCollections are the ones that grew a `version` column in
// the R3 schema migrations. Placemarks, determinations, photos,
// people, label_pdfs are not in the list because the Spec does not
// require LWW-style conflict detection for them.
var versionedCollections = []string{
	"samples",
	"fieldtrips",
	"localities",
}

// RegisterVersionConflictGuards wires the version-check hook on
// every versioned collection. Call once at boot from main.go.
func RegisterVersionConflictGuards(app *pocketbase.PocketBase) {
	for _, name := range versionedCollections {
		app.OnRecordBeforeUpdateRequest(name).Add(func(e *core.RecordUpdateEvent) error {
			return enforceVersion(e.Record)
		})
	}
}

func enforceVersion(rec *models.Record) error {
	original := rec.OriginalCopy()
	current := original.GetInt("version")
	incoming := rec.GetInt("version")

	switch {
	case incoming == 0:
		// Legacy client that doesn't know about version. Accept and
		// bump on the server.
	case incoming <= current:
		// Stale write — somebody else (or we ourselves on another
		// device) already incremented past this. The client must
		// pull the fresh row and either retry or surface a merge.
		return apis.NewApiError(
			http.StatusConflict,
			"stale write: pull and retry",
			map[string]any{
				"current_version":  current,
				"incoming_version": incoming,
			},
		)
	}

	// Happy path: the server is the canonical source for the post-
	// write counter. Even if the client supplied current+1, we
	// rewrite it so the response carries the value the next push
	// will need.
	rec.Set("version", current+1)
	return nil
}
