// Package hooks adapts the pure logic in internal/codes and
// internal/grouping to PocketBase: it implements grouping.Repo on top
// of a core.App, and wires the create/update request hooks on the
// samples collection.
//
// Phase 11 changes: the owner is read from the authenticated user of
// the request (core.RequestEvent.Auth). The legacy `user_id` text
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
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

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
//  2. takes the collecting_day from the client or computes it from
//     begin_date in the sample's timezone under the user's rollover,
//  3. finds or creates the matching fieldtrip for (owner, day) and
//     extends its time window to include the new sample,
//  4. keeps the sample_id as sent (only a per-owner collision gets a
//     " (n)" suffix, the sent value goes to original_code),
//  5. populates `fieldtrip` and `owner` so PocketBase's subsequent
//     save sees a complete sample.
func RegisterSampleCreate(app core.App) {
	app.OnRecordCreateRequest("samples").BindFunc(func(e *core.RecordRequestEvent) error {
		ownerID, err := authOwnerID(e.Auth)
		if err != nil {
			return err
		}
		if err := processSample(e.App, e.Record, ownerID); err != nil {
			return err
		}
		return e.Next()
	})
}

// RegisterOwnerSetters fills `owner` from the auth record on
// collections that don't have any other create-time computation. The
// client is allowed to omit `owner` from the request body; the hook
// fills it. If the client did supply a non-empty `owner` it must
// match the authenticated user (otherwise we'd let A claim records
// for B even with our rules in place, because rules apply post-write
// on update/delete but not on create).
func RegisterOwnerSetters(app core.App) {
	for _, name := range []string{"fieldtrips", "localities", "people", "determinations", "sample_photos"} {
		app.OnRecordCreateRequest(name).BindFunc(func(e *core.RecordRequestEvent) error {
			ownerID, err := authOwnerID(e.Auth)
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
			return e.Next()
		})
	}
}

// authOwnerID returns the id of the authenticated user record. The
// collection's CreateRule (`@request.auth.id != ”`) blocks the request
// before our hook ever runs, but we check defensively in case the rules
// ever loosen. Superusers are no `users` record and get the same 401 as
// 0.22 admins did (they were no auth record there).
func authOwnerID(auth *core.Record) (string, error) {
	if auth != nil && !auth.IsSuperuser() {
		return auth.Id, nil
	}
	return "", apis.NewUnauthorizedError("authentication required", nil)
}

func processSample(app core.App, rec *core.Record, ownerID string) error {
	collectedFrom := rec.GetDateTime("begin_date").Time()
	if collectedFrom.IsZero() {
		collectedFrom = time.Now()
		rec.Set("begin_date", collectedFrom)
	}

	cutoff := 0
	if user, err := app.FindRecordById("users", ownerID); err == nil {
		cutoff = user.GetInt("day_cutoff_hour")
	}
	day, loc := collectingDayFor(rec, cutoff)
	rec.Set("collecting_day", day.Format("2006-01-02"))
	collectedLocal := collectedFrom.In(loc)

	// The sample_id is the client's; the backend only resolves
	// per-owner collisions with a " (n)" suffix. Whitespace-only
	// counts as empty.
	wanted := rec.GetString("sample_id")
	if strings.TrimSpace(wanted) == "" {
		wanted = ""
	}

	var (
		ftID    string
		finalID string
	)
	err := app.RunInTransaction(func(txApp core.App) error {
		repo := newPBRepo(txApp)
		ft, err := grouping.FindOrCreate(repo, ownerID, day, collectedLocal)
		if err != nil {
			return fmt.Errorf("fieldtrip: %w", err)
		}
		ftID = ft.ID

		finalID, err = uniqueSampleID(txApp, ownerID, wanted, "")
		if err != nil {
			return fmt.Errorf("sample_id: %w", err)
		}
		return nil
	})
	if err != nil {
		return err
	}

	rec.Set("fieldtrip", ftID)
	rec.Set("owner", ownerID)
	rec.Set("sample_id", finalID)
	if finalID != wanted {
		rec.Set("original_code", wanted)
	}
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

// loadLocation resolves an IANA name; empty or invalid falls back to
// Europe/Berlin (legacy data without a timezone).
func loadLocation(name string) *time.Location {
	name = strings.TrimSpace(name)
	if name == "" {
		return berlin
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return berlin
	}
	return loc
}

// collectingDayFor returns the collecting day of a sample and the
// location it was computed in. A valid `collecting_day` sent by the
// client wins; otherwise the day is derived from begin_date in the
// sample's timezone under the given rollover hour.
func collectingDayFor(rec *core.Record, cutoffHour int) (time.Time, *time.Location) {
	loc := loadLocation(rec.GetString("timezone"))
	if d, err := time.ParseInLocation("2006-01-02", rec.GetString("collecting_day"), loc); err == nil {
		return d, loc
	}
	begin := rec.GetDateTime("begin_date").Time()
	if begin.IsZero() {
		begin = time.Now()
	}
	return codes.CollectingDay(begin.In(loc), cutoffHour), loc
}

// uniqueSampleID makes `wanted` unique among the owner's samples
// (excluding excludeID): "" stays "", a free ID is kept, a taken one
// gets the smallest free " (n)" suffix with n >= 2.
func uniqueSampleID(app core.App, ownerID, wanted, excludeID string) (string, error) {
	if wanted == "" {
		return "", nil
	}
	taken := func(id string) (bool, error) {
		_, err := app.FindFirstRecordByFilter(
			"samples",
			"owner = {:o} && sample_id = {:s} && id != {:x}",
			dbx.Params{"o": ownerID, "s": id, "x": excludeID},
		)
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		return true, nil
	}
	candidate := wanted
	for n := 1; ; n++ {
		if n > 1 {
			candidate = fmt.Sprintf("%s (%d)", wanted, n)
		}
		t, err := taken(candidate)
		if err != nil {
			return "", err
		}
		if !t {
			return candidate, nil
		}
	}
}

// RegisterSampleIDUpdate keeps (owner, sample_id) unique when a
// client edits the ID: only a changed ID is checked, collisions get
// the " (n)" suffix and the sent ID lands in original_code.
func RegisterSampleIDUpdate(app core.App) {
	app.OnRecordUpdateRequest("samples").BindFunc(func(e *core.RecordRequestEvent) error {
		keepStrongerTimezone(e.Record)
		if err := followCollectingDayOnUpdate(e.App, e.Record); err != nil {
			return err
		}
		if err := resolveSampleIDOnUpdate(e.App, e.Record); err != nil {
			return err
		}
		return e.Next()
	})
}

// keepStrongerTimezone refuses to downgrade timezone_source from
// location_service/manual to device: a stale client (409 retry, second
// device) must not push its device zone over the Ortus or user zone.
// The stored timezone + source stay in that case.
func keepStrongerTimezone(rec *core.Record) {
	orig := rec.Original()
	if orig == nil {
		return
	}
	was := orig.GetString("timezone_source")
	if was != "location_service" && was != "manual" {
		return
	}
	if rec.GetString("timezone_source") == "device" {
		rec.Set("timezone", orig.GetString("timezone"))
		rec.Set("timezone_source", was)
	}
}

// followCollectingDayOnUpdate keeps the fieldtrip in line with the
// collecting day of retrospective samples ("nachgetragen"):
//
//   - is_retrospective is create-only; a flipped value is reset to the
//     stored one, so a field sample can never become retrospective.
//   - A field sample keeps its stored collecting_day (the client value
//     is ignored) and with it its fieldtrip.
//   - A retrospective sample whose collecting_day changed moves to the
//     fieldtrip of the new day (found or created, window extended like
//     on create). The old fieldtrip stays untouched, even when empty.
//     The sample_id is not touched here.
func followCollectingDayOnUpdate(app core.App, rec *core.Record) error {
	orig := rec.Original()
	if orig == nil {
		return nil
	}
	retro := orig.GetBool("is_retrospective")
	rec.Set("is_retrospective", retro)

	oldDay := orig.GetString("collecting_day")
	if !retro {
		if oldDay != "" {
			rec.Set("collecting_day", oldDay)
		}
		return nil
	}

	newDay := rec.GetString("collecting_day")
	if newDay == oldDay {
		return nil
	}
	loc := loadLocation(rec.GetString("timezone"))
	day, err := time.ParseInLocation("2006-01-02", newDay, loc)
	if err != nil {
		// Not a valid day: keep the stored one. A malformed client value
		// is not an error for the update.
		rec.Set("collecting_day", oldDay)
		return nil //nolint:nilerr // invalid day is silently corrected, not rejected
	}
	begin := rec.GetDateTime("begin_date").Time()
	if begin.IsZero() {
		begin = day
	}
	ownerID := rec.GetString("owner")
	var ftID string
	err = app.RunInTransaction(func(txApp core.App) error {
		ft, err := grouping.FindOrCreate(newPBRepo(txApp), ownerID, day, begin.In(loc))
		if err != nil {
			return fmt.Errorf("fieldtrip: %w", err)
		}
		ftID = ft.ID
		return nil
	})
	if err != nil {
		return err
	}
	rec.Set("fieldtrip", ftID)
	return nil
}

func resolveSampleIDOnUpdate(app core.App, rec *core.Record) error {
	wanted := rec.GetString("sample_id")
	if strings.TrimSpace(wanted) == "" {
		rec.Set("sample_id", "")
		return nil
	}
	if orig := rec.Original(); orig != nil && orig.GetString("sample_id") == wanted {
		return nil
	}
	final, err := uniqueSampleID(app, rec.GetString("owner"), wanted, rec.Id)
	if err != nil {
		return err
	}
	if final != wanted {
		rec.Set("sample_id", final)
		rec.Set("original_code", wanted)
	}
	return nil
}

// pbRepo implements grouping.Repo on top of a PocketBase app.
type pbRepo struct {
	app  core.App
	coll *core.Collection
}

func newPBRepo(app core.App) *pbRepo {
	coll, _ := app.FindCollectionByNameOrId("fieldtrips")
	return &pbRepo{app: app, coll: coll}
}

func (r *pbRepo) FindByUserAndDay(ownerID string, day time.Time) (*grouping.Fieldtrip, error) {
	dayStr := day.Format("2006-01-02")
	rec, err := r.app.FindFirstRecordByFilter(
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
	rec := core.NewRecord(r.coll)
	writeFieldtrip(rec, e)
	// Like 0.22's dao.SaveRecord: no validation, hooks of other
	// requests are not involved.
	if err := r.app.SaveNoValidate(rec); err != nil {
		return err
	}
	e.ID = rec.Id
	return nil
}

func (r *pbRepo) Update(e *grouping.Fieldtrip) error {
	rec, err := r.app.FindRecordById("fieldtrips", e.ID)
	if err != nil {
		return err
	}
	writeFieldtrip(rec, e)
	return r.app.SaveNoValidate(rec)
}

func fieldtripFromRecord(rec *core.Record) *grouping.Fieldtrip {
	loc := loadLocation(rec.GetString("timezone"))
	day, _ := time.ParseInLocation("2006-01-02", rec.GetString("collecting_day"), loc)
	// PocketBase returns datetimes in UTC. We convert to the user's
	// TZ so grouping.SpansMidnight evaluates against local calendar
	// dates (a 22:00→01:30 window must register as crossing
	// midnight, even though both instants share a UTC day).
	return &grouping.Fieldtrip{
		ID:        rec.Id,
		UserID:    rec.GetString("owner"),
		Day:       day,
		StartedAt: rec.GetDateTime("begin_date").Time().In(loc),
		EndedAt:   rec.GetDateTime("end_date").Time().In(loc),
		Night:     rec.GetBool("night_fieldtrip"),
	}
}

func writeFieldtrip(rec *core.Record, e *grouping.Fieldtrip) {
	rec.Set("owner", e.UserID)
	rec.Set("collecting_day", e.Day.Format("2006-01-02"))
	rec.Set("begin_date", e.StartedAt)
	rec.Set("end_date", e.EndedAt)
	rec.Set("night_fieldtrip", e.Night)
	// Only written while empty: a new fieldtrip takes the location of
	// its window start, i.e. the zone of its first sample. A legacy row
	// without a zone is backfilled with whatever location StartedAt
	// carries then — Berlin (via loadLocation) unless ExpandWindow
	// replaced the start with the sample's own, differently zoned time.
	if strings.TrimSpace(rec.GetString("timezone")) == "" {
		rec.Set("timezone", e.StartedAt.Location().String())
	}
	if rec.GetString("title") == "" {
		rec.Set("title", "Sammeltag "+e.Day.Format("02.01.2006"))
	}
}
