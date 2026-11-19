// Phase S — Fotos im Original.
//
//   - sample_photos.photo_file: MaxSize 10 MB → 50 MB. The app no longer
//     downscales photos; a full-resolution JPEG can exceed 10 MB.
//   - Unique index on (owner, client_uuid) for non-empty uuids: a
//     repeated upload (timeout, retry) must not store a photo twice,
//     also when the first request is still running. Duplicates from
//     before the index keep their files; the later rows lose their
//     uuid so the index can be created.
//
// Down sets 10 MB again (existing larger files stay stored) and drops
// the index.
package migrations

import (
	"errors"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

const (
	phaseSPhotoMaxSize       = 50 * 1024 * 1024
	phaseSPhotoLegacyMaxSize = 10 * 1024 * 1024
)

func phaseSSetPhotoMaxSize(app core.App, size int64) error {
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		return err
	}
	f, ok := coll.Fields.GetByName("photo_file").(*core.FileField)
	if !ok {
		return errors.New("sample_photos.photo_file is not a file field")
	}
	f.MaxSize = size
	return app.Save(coll)
}

// phaseSPhotoUUIDIndex makes (owner, client_uuid) unique for photos that
// carry a uuid.
const phaseSPhotoUUIDIndex = "idx_sample_photos_owner_client_uuid_unique"

func phaseSPhotoLimitUp(app core.App) error {
	if err := phaseSSetPhotoMaxSize(app, phaseSPhotoMaxSize); err != nil {
		return err
	}
	// Keep the oldest row of every duplicate group as the holder of the
	// uuid; nothing is deleted.
	if _, err := app.DB().NewQuery(`UPDATE sample_photos SET client_uuid = ''
		WHERE client_uuid != '' AND rowid NOT IN (
			SELECT MIN(rowid) FROM sample_photos WHERE client_uuid != '' GROUP BY owner, client_uuid
		)`).Execute(); err != nil {
		return err
	}
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		return err
	}
	coll.AddIndex(phaseSPhotoUUIDIndex, true, "owner, client_uuid", "client_uuid != ''")
	return app.Save(coll)
}

func phaseSPhotoLimitDown(app core.App) error {
	coll, err := app.FindCollectionByNameOrId("sample_photos")
	if err != nil {
		return err
	}
	coll.RemoveIndex(phaseSPhotoUUIDIndex)
	if err := app.Save(coll); err != nil {
		return err
	}
	return phaseSSetPhotoMaxSize(app, phaseSPhotoLegacyMaxSize)
}

func init() {
	m.Register(phaseSPhotoLimitUp, phaseSPhotoLimitDown)
}
