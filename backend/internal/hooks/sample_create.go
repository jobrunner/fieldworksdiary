// Package hooks adapts the pure logic in internal/codes and
// internal/grouping to PocketBase: it implements grouping.Repo on top
// of a daos.Dao, allocates the per-(owner, day) sequence atomically,
// and wires the BeforeCreate request hook on the samples collection.
//
// Phase 11 changes: the owner is read from the authenticated user in
// the request context (apis.RequestInfo). The legacy `user_id` text
// field is gone — every collection now uses `owner` (relation →
// users) for scoping.
package hooks

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.mett.io/fwd-backend/internal/codes"
	"go.mett.io/fwd-backend/internal/grouping"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
)

// Phase-1 default: the cutoff hour is fixed for now. It moves to
// `users.day_cutoff_hour` per-user once we wire the user-settings UI.
const defaultCutoff = 5

var berlin = func() *time.Location {
	loc, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		panic("Europe/Berlin tzdata missing: " + err.Error())
	}
	return loc
}()

// RegisterSampleCreate wires the auto-grouping + code-vergabe hook on
// the samples collection. The hook:
//
//  1. requires an authenticated user (the CreateRule does too, but
//     defence in depth — we panic-proof the hook),
//  2. computes the collecting_day from collected_from (default = now)
//     in Europe/Berlin under a 5 h rollover,
//  3. finds or creates the matching fieldtrip for (owner, day) and
//     extends its time window to include the new sample,
//  4. allocates the next sequence number atomically,
//  5. populates the record's `code`, `fieldtrip` and `owner` so
//     PocketBase's subsequent save sees a complete sample.
func RegisterSampleCreate(app *pocketbase.PocketBase) {
	app.OnRecordBeforeCreateRequest("samples").Add(func(e *core.RecordCreateEvent) error {
		ownerID, err := authOwnerID(e.HttpContext)
		if err != nil {
			return err
		}
		return processSample(app.Dao(), e.Record, ownerID)
	})
}

// RegisterOwnerSetters fills `owner` from the auth record on
// collections that don't have any other create-time computation. The
// client is allowed to omit `owner` from the request body; the hook
// fills it. If the client did supply a non-empty `owner` it must
// match the authenticated user (otherwise we'd let A claim records
// for B even with our rules in place, because rules apply post-write
// on update/delete but not on create).
func RegisterOwnerSetters(app *pocketbase.PocketBase) {
	for _, name := range []string{"fieldtrips", "localities", "people", "determinations", "sample_photos"} {
		app.OnRecordBeforeCreateRequest(name).Add(func(e *core.RecordCreateEvent) error {
			ownerID, err := authOwnerID(e.HttpContext)
			if err != nil {
				return err
			}
			incoming := strings.TrimSpace(e.Record.GetString("owner"))
			if incoming != "" && incoming != ownerID {
				return apis.NewForbiddenError(
					"owner must match the authenticated user", nil,
				)
			}
			e.Record.Set("owner", ownerID)
			return nil
		})
	}
}

// authOwnerID returns the auth record's id. The collection's
// CreateRule (`@request.auth.id != ”`) blocks the request before
// our hook ever runs, but we type-check defensively in case the
// rules ever loosen. We read `ContextAuthRecordKey` directly —
// `ContextRequestInfoKey` is only populated by the collection
// handler's RequestInfo init, not by the global LoadAuthContext
// pre-middleware.
func authOwnerID(c interface {
	Get(string) any
},
) (string, error) {
	if rec, _ := c.Get(apis.ContextAuthRecordKey).(*models.Record); rec != nil {
		return rec.Id, nil
	}
	return "", apis.NewUnauthorizedError("authentication required", nil)
}

func processSample(dao *daos.Dao, rec *models.Record, ownerID string) error {
	collectedFrom := rec.GetDateTime("begin_date").Time()
	if collectedFrom.IsZero() {
		collectedFrom = time.Now()
		rec.Set("begin_date", collectedFrom)
	}
	collectedLocal := collectedFrom.In(berlin)
	day := codes.CollectingDay(collectedLocal, defaultCutoff)
	dayStr := day.Format("2006-01-02")

	incomingCode := strings.TrimSpace(rec.GetString("sample_id"))

	var (
		ftID      string
		finalCode string
	)
	err := dao.RunInTransaction(func(txDao *daos.Dao) error {
		repo := newPBRepo(txDao)
		ft, err := grouping.FindOrCreate(repo, ownerID, day, collectedLocal)
		if err != nil {
			return fmt.Errorf("fieldtrip: %w", err)
		}
		ftID = ft.ID

		if incomingCode != "" {
			// Honor the client-supplied code unless it collides with
			// one already issued. Collision case is rare (multi-device
			// offline) but the audit trail matters — the user wrote
			// the original on the tube.
			conflict, err := codeConflicts(txDao, incomingCode)
			if err != nil {
				return fmt.Errorf("conflict check: %w", err)
			}
			if !conflict {
				finalCode = incomingCode
				if n, ok := codes.ParseSequence(incomingCode); ok {
					if err := ensureSequenceAtLeast(txDao, ownerID, dayStr, n); err != nil {
						return fmt.Errorf("sequence raise: %w", err)
					}
				}
				return nil
			}
			s, err := nextSequence(txDao, ownerID, dayStr)
			if err != nil {
				return fmt.Errorf("sequence: %w", err)
			}
			finalCode = codes.FormatCode(day, s)
			rec.Set("original_code", incomingCode)
			return nil
		}

		s, err := nextSequence(txDao, ownerID, dayStr)
		if err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		finalCode = codes.FormatCode(day, s)
		return nil
	})
	if err != nil {
		return err
	}

	rec.Set("fieldtrip", ftID)
	rec.Set("owner", ownerID)
	rec.Set("sample_id", finalCode)
	// Without location data from the client the backend enrichment
	// fills the place after the insert (see internal/enrichment).
	if strings.TrimSpace(rec.GetString("location_status")) == "" {
		rec.Set("location_status", "pending")
	}
	// A client-supplied height without a source is the device's GPS
	// height; tagging it keeps the DEM enrichment from replacing it.
	if rec.GetFloat("elevation") != 0 && strings.TrimSpace(rec.GetString("elevation_source")) == "" {
		rec.Set("elevation_source", "location_service")
	}
	return nil
}

// codeConflicts checks for an existing sample with this sample_id
// under any owner. Sample IDs are not globally unique post-Phase-3b,
// but we honour-or-reassign per user; here we only need to know if
// reusing would collide.
func codeConflicts(dao *daos.Dao, code string) (bool, error) {
	rec, err := dao.FindFirstRecordByFilter(
		"samples",
		"sample_id = {:c}",
		dbx.Params{"c": code},
	)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return rec != nil, nil
}

// ensureSequenceAtLeast raises the (owner, day) counter to `n` if it
// is currently lower. Creates the row if missing. Idempotent.
func ensureSequenceAtLeast(dao *daos.Dao, ownerID, dayStr string, n int) error {
	coll, err := dao.FindCollectionByNameOrId("sample_sequences")
	if err != nil {
		return err
	}

	rec, err := dao.FindFirstRecordByFilter(
		"sample_sequences",
		"owner = {:o} && collecting_day = {:day}",
		dbx.Params{"o": ownerID, "day": dayStr},
	)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	if rec == nil {
		rec = models.NewRecord(coll)
		rec.Set("owner", ownerID)
		rec.Set("collecting_day", dayStr)
		rec.Set("last_seq", n)
		return dao.SaveRecord(rec)
	}
	if rec.GetInt("last_seq") < n {
		rec.Set("last_seq", n)
		return dao.SaveRecord(rec)
	}
	return nil
}

// nextSequence increments and returns the per-(owner, day) counter.
// The unique index on (owner, collecting_day) plus the surrounding
// transaction give us atomic increment.
func nextSequence(dao *daos.Dao, ownerID, dayStr string) (int, error) {
	coll, err := dao.FindCollectionByNameOrId("sample_sequences")
	if err != nil {
		return 0, err
	}

	rec, err := dao.FindFirstRecordByFilter(
		"sample_sequences",
		"owner = {:o} && collecting_day = {:day}",
		dbx.Params{"o": ownerID, "day": dayStr},
	)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}

	if rec == nil {
		rec = models.NewRecord(coll)
		rec.Set("owner", ownerID)
		rec.Set("collecting_day", dayStr)
		rec.Set("last_seq", 1)
	} else {
		rec.Set("last_seq", rec.GetInt("last_seq")+1)
	}
	if err := dao.SaveRecord(rec); err != nil {
		return 0, err
	}
	return rec.GetInt("last_seq"), nil
}

// pbRepo implements grouping.Repo on top of a PocketBase dao.
type pbRepo struct {
	dao  *daos.Dao
	coll *models.Collection
}

func newPBRepo(dao *daos.Dao) *pbRepo {
	coll, _ := dao.FindCollectionByNameOrId("fieldtrips")
	return &pbRepo{dao: dao, coll: coll}
}

func (r *pbRepo) FindByUserAndDay(ownerID string, day time.Time) (*grouping.Fieldtrip, error) {
	dayStr := day.Format("2006-01-02")
	rec, err := r.dao.FindFirstRecordByFilter(
		"fieldtrips",
		"owner = {:o} && collecting_day = {:day}",
		dbx.Params{"o": ownerID, "day": dayStr},
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, grouping.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return fieldtripFromRecord(rec), nil
}

func (r *pbRepo) Create(e *grouping.Fieldtrip) error {
	rec := models.NewRecord(r.coll)
	writeFieldtrip(rec, e)
	if err := r.dao.SaveRecord(rec); err != nil {
		return err
	}
	e.ID = rec.Id
	return nil
}

func (r *pbRepo) Update(e *grouping.Fieldtrip) error {
	rec, err := r.dao.FindRecordById("fieldtrips", e.ID)
	if err != nil {
		return err
	}
	writeFieldtrip(rec, e)
	return r.dao.SaveRecord(rec)
}

func fieldtripFromRecord(rec *models.Record) *grouping.Fieldtrip {
	day, _ := time.ParseInLocation("2006-01-02", rec.GetString("collecting_day"), berlin)
	// PocketBase returns datetimes in UTC. We convert to the user's
	// TZ so grouping.SpansMidnight evaluates against local calendar
	// dates (a 22:00→01:30 window must register as crossing
	// midnight, even though both instants share a UTC day).
	return &grouping.Fieldtrip{
		ID:        rec.Id,
		UserID:    rec.GetString("owner"),
		Day:       day,
		StartedAt: rec.GetDateTime("begin_date").Time().In(berlin),
		EndedAt:   rec.GetDateTime("end_date").Time().In(berlin),
		Night:     rec.GetBool("night_fieldtrip"),
	}
}

func writeFieldtrip(rec *models.Record, e *grouping.Fieldtrip) {
	rec.Set("owner", e.UserID)
	rec.Set("collecting_day", e.Day.Format("2006-01-02"))
	rec.Set("begin_date", e.StartedAt)
	rec.Set("end_date", e.EndedAt)
	rec.Set("night_fieldtrip", e.Night)
	if rec.GetString("title") == "" {
		rec.Set("title", "Sammeltag "+e.Day.Format("02.01.2006"))
	}
}
