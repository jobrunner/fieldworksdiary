package hooks

import (
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// existingSample returns the caller's sample with this client_uuid, or
// nil. An empty uuid or owner never matches.
func existingSample(app core.App, ownerID, clientUUID string) *core.Record {
	clientUUID = strings.TrimSpace(clientUUID)
	if ownerID == "" || clientUUID == "" {
		return nil
	}
	rec, err := app.FindFirstRecordByFilter("samples",
		"owner = {:o} && client_uuid = {:u}", dbx.Params{"o": ownerID, "u": clientUUID})
	if err != nil {
		return nil
	}
	return rec
}

// replayHeader marks a create response that carries a sample stored by
// an earlier request. The body of the repeated request was not applied;
// a client that changed the sample between its attempts sends those
// changes as an update.
const replayHeader = "Idempotent-Replayed"

func replayExistingSample(e *core.RecordRequestEvent, existing *core.Record) error {
	e.Response.Header().Set(replayHeader, "true")
	return e.JSON(http.StatusOK, existing)
}
