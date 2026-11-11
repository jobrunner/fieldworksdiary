// Phase R6.1 — locality-fusion hook. Adapts the pure logic in
// `internal/fusion` to PocketBase:
//
//   - On every locality create + on every locality update where the
//     coordinate moved > 100 m, we re-run ServerFuse.
//   - MergeInto: hang the incoming locality's samples onto the
//     target, emit a `locality_remap_events` row, delete the
//     incoming locality.
//   - FlagAmbiguous: set `needs_human_review = true`.
//   - KeepAsIs: no-op.
//
// The work happens in a goroutine with a `recover` guard so a
// fusion misstep can't bring the originating locality save down.
package hooks

import (
	"encoding/json"
	"log/slog"
	"runtime/debug"

	"go.mett.io/fwd-backend/internal/fusion"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// FusionRunner is the side of the hook that touches the DB. Pulled
// out so future tests can swap the lookup against a fake.
type FusionRunner struct {
	App      core.App
	Settings fusion.Settings
	Logger   *slog.Logger
}

// RegisterLocalityFusion wires the create + update hooks on the
// localities collection. Pass a zero-value Settings for the
// Spec-defaults (MinRadius = 50 m).
func RegisterLocalityFusion(app core.App, settings fusion.Settings) {
	runner := &FusionRunner{App: app, Settings: settings}

	app.OnRecordCreateRequest("localities").BindFunc(func(ev *core.RecordRequestEvent) error {
		if err := ev.Next(); err != nil {
			return err
		}
		// Always run fusion on create — the row didn't exist
		// before, so by definition the coordinate is "new".
		id := ev.Record.Id
		go runner.runSafely(id)
		return nil
	})

	app.OnRecordUpdateRequest("localities").BindFunc(func(ev *core.RecordRequestEvent) error {
		// The pre-update state, captured before the save.
		original := ev.Record.Original()
		if err := ev.Next(); err != nil {
			return err
		}
		// Only re-fuse if the centroid actually moved past the
		// significance threshold. Otherwise every `notes` edit
		// would spam the hook.
		prevLat := original.GetFloat("latitude")
		prevLon := original.GetFloat("longitude")
		newLat := ev.Record.GetFloat("latitude")
		newLon := ev.Record.GetFloat("longitude")
		if !fusion.SignificantCoordChange(prevLat, prevLon, newLat, newLon) {
			return nil
		}
		id := ev.Record.Id
		go runner.runSafely(id)
		return nil
	})
}

func (r *FusionRunner) log() *slog.Logger {
	if r.Logger != nil {
		return r.Logger
	}
	return r.App.Logger()
}

// runSafely is the goroutine entry point. Wraps the actual work in
// a recover so a panic in fusion never escapes the goroutine.
func (r *FusionRunner) runSafely(localityID string) {
	defer func() {
		if rec := recover(); rec != nil {
			r.log().Error(
				"fusion panic",
				slog.String("locality_id", localityID),
				slog.Any("recover", rec),
				slog.String("stack", string(debug.Stack())),
			)
		}
	}()
	if err := r.run(localityID); err != nil {
		r.log().Warn(
			"fusion failed",
			slog.String("locality_id", localityID),
			slog.Any("err", err),
		)
	}
}

func (r *FusionRunner) run(localityID string) error {
	app := r.App
	loc, err := app.FindRecordById("localities", localityID)
	if err != nil {
		return err
	}

	owner := loc.GetString("owner")
	if owner == "" {
		// Pre-Phase-11 row — nothing to fuse against safely.
		return nil
	}

	incoming := fusion.Candidate{
		ID:                 loc.Id,
		Latitude:           loc.GetFloat("latitude"),
		Longitude:          loc.GetFloat("longitude"),
		HorizontalAccuracy: loc.GetFloat("horizontal_accuracy"),
	}
	// A locality with no coordinate isn't a useful fusion subject.
	if incoming.Latitude == 0 && incoming.Longitude == 0 {
		return nil
	}

	candRecords, err := app.FindRecordsByFilter(
		"localities",
		"owner = {:o} && id != {:id}",
		"",
		500, 0,
		dbx.Params{"o": owner, "id": loc.Id},
	)
	if err != nil {
		return err
	}
	candidates := make([]fusion.Candidate, 0, len(candRecords))
	for _, c := range candRecords {
		lat := c.GetFloat("latitude")
		lon := c.GetFloat("longitude")
		if lat == 0 && lon == 0 {
			continue
		}
		candidates = append(candidates, fusion.Candidate{
			ID:                 c.Id,
			Latitude:           lat,
			Longitude:          lon,
			HorizontalAccuracy: c.GetFloat("horizontal_accuracy"),
		})
	}

	decision := fusion.ServerFuse(incoming, candidates, r.Settings)
	switch decision.Kind {
	case fusion.KeepAsIs:
		return r.clearReviewFlag(loc)
	case fusion.MergeInto:
		return r.mergeInto(app, loc, decision.TargetID)
	case fusion.FlagAmbiguous:
		return r.setReviewFlag(loc)
	}
	return nil
}

// clearReviewFlag drops a stale needs_human_review = true that no
// longer applies (centroid moved out of the duplicate radius).
func (r *FusionRunner) clearReviewFlag(loc *core.Record) error {
	if !loc.GetBool("needs_human_review") {
		return nil
	}
	loc.Set("needs_human_review", false)
	return r.App.SaveNoValidate(loc)
}

func (r *FusionRunner) setReviewFlag(loc *core.Record) error {
	if loc.GetBool("needs_human_review") {
		return nil
	}
	loc.Set("needs_human_review", true)
	return r.App.SaveNoValidate(loc)
}

// mergeInto:
//
//  1. Re-points every sample whose `locality = incoming` to
//     `target`. Collects the moved sample ids.
//  2. Emits a `locality_remap_events` row tagged with the owner so
//     the client can poll its own stream.
//  3. Deletes the incoming locality.
//
// Wrapped in a transaction so a partial failure doesn't leave the
// DB with samples pointing at a deleted locality.
func (r *FusionRunner) mergeInto(app core.App, loc *core.Record, targetID string) error {
	if targetID == loc.Id {
		// Defensive: ServerFuse should already have excluded self,
		// but a re-check costs nothing.
		return nil
	}

	owner := loc.GetString("owner")
	incomingID := loc.Id

	return app.RunInTransaction(func(txApp core.App) error {
		samples, err := txApp.FindRecordsByFilter(
			"samples",
			"locality = {:l}",
			"",
			0, 0,
			dbx.Params{"l": incomingID},
		)
		if err != nil {
			return err
		}
		movedSampleIDs := make([]string, 0, len(samples))
		for _, s := range samples {
			s.Set("locality", targetID)
			if err := txApp.SaveNoValidate(s); err != nil {
				return err
			}
			movedSampleIDs = append(movedSampleIDs, s.Id)
		}

		// Emit the remap event before the delete so a poll that
		// races us still sees a coherent (old → new) pair plus
		// the new target row.
		eventColl, err := txApp.FindCollectionByNameOrId("locality_remap_events")
		if err != nil {
			return err
		}
		event := core.NewRecord(eventColl)
		event.Set("owner", owner)
		event.Set("old_locality_id", incomingID)
		event.Set("new_locality_id", targetID)
		event.Set("reason", "merged_with_existing")
		idsJSON, err := json.Marshal(movedSampleIDs)
		if err != nil {
			return err
		}
		event.Set("affected_sample_ids", string(idsJSON))
		if err := txApp.SaveNoValidate(event); err != nil {
			return err
		}

		// Finally, drop the now-empty duplicate.
		return txApp.Delete(loc)
	})
}
