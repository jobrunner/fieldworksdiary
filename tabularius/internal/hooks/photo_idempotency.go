package hooks

import (
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterPhotoIdempotency makes the upload of a sample photo
// repeatable: a create request whose client_uuid the caller already
// uploaded answers with the existing record instead of storing the file
// a second time. The app repeats an upload after a timeout without
// knowing whether the first attempt arrived. The unique index on
// (owner, client_uuid) covers the case that the first request is still
// running.
func RegisterPhotoIdempotency(app core.App) {
	app.OnRecordCreateRequest("sample_photos").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.Next()
		}
		ownerID, clientUUID := e.Auth.Id, e.Record.GetString("client_uuid")
		if existing := existingPhoto(e.App, ownerID, clientUUID); existing != nil {
			return e.JSON(http.StatusOK, existing)
		}
		err := e.Next()
		if err == nil {
			return nil
		}
		// Two requests with the same uuid at once: both miss the lookup
		// above, the unique index lets one through. The loser answers
		// with the winner's record.
		if existing := existingPhoto(e.App, ownerID, clientUUID); existing != nil {
			return e.JSON(http.StatusOK, existing)
		}
		return err
	})
}

// existingPhoto returns the caller's photo with this client_uuid, or
// nil. An empty uuid (clients from before the field was sent) or owner
// never matches.
func existingPhoto(app core.App, ownerID, clientUUID string) *core.Record {
	clientUUID = strings.TrimSpace(clientUUID)
	if ownerID == "" || clientUUID == "" {
		return nil
	}
	rec, err := app.FindFirstRecordByFilter("sample_photos",
		"owner = {:o} && client_uuid = {:u}", dbx.Params{"o": ownerID, "u": clientUUID})
	if err != nil {
		return nil
	}
	return rec
}
