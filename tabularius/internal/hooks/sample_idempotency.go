package hooks

import (
	"hash/fnv"
	"net/http"
	"sync"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// existingSample returns the caller's sample with this client_uuid, or
// nil. An empty uuid or owner never matches. The uuid is compared as
// stored: PocketBase keeps whitespace, and the unique index treats every
// non-empty value as a key, also one that is only whitespace.
func existingSample(app core.App, ownerID, clientUUID string) *core.Record {
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
	// As the regular create response: expands, hidden fields.
	if err := apis.EnrichRecord(e.RequestEvent, existing); err != nil {
		return err
	}
	e.Response.Header().Set(replayHeader, "true")
	return e.JSON(http.StatusOK, existing)
}

// keepClientUUIDOfDuplicate leaves the stored client_uuid in place when
// an update sends one that another sample of the owner holds. That is
// the device of a duplicate from before the unique index: the migration
// cleared the uuid of the later rows, the device still sends the old one
// with every PATCH. Without this its edits would fail against the index.
// A uuid nobody else holds is taken over as before.
func keepClientUUIDOfDuplicate(app core.App, rec *core.Record) {
	orig := rec.Original()
	if orig == nil {
		return
	}
	incoming := rec.GetString("client_uuid")
	if incoming == "" || incoming == orig.GetString("client_uuid") {
		return
	}
	_, err := app.FindFirstRecordByFilter("samples",
		"owner = {:o} && client_uuid = {:u} && id != {:id}",
		dbx.Params{"o": orig.GetString("owner"), "u": incoming, "id": rec.Id})
	if err != nil {
		return
	}
	rec.Set("client_uuid", orig.GetString("client_uuid"))
}

// createLocks serialises the creates of one (owner, client_uuid) inside
// this process: lookup, grouping and save of a request run as a unit,
// so an overlapping repeat finds the stored sample instead of grouping
// a second time. Tabularius runs as a single process on SQLite; the
// unique index stays the guarantee should that ever change. A fixed
// number of stripes keeps the memory constant.
var createLocks [64]sync.Mutex

func lockSampleCreate(ownerID, clientUUID string) (unlock func()) {
	if clientUUID == "" {
		return func() {}
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(ownerID + "\x00" + clientUUID))
	mu := &createLocks[h.Sum32()%uint32(len(createLocks))]
	mu.Lock()
	return mu.Unlock
}
