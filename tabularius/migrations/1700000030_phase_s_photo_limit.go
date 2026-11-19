// Phase S — Fotos im Original.
//
//   - sample_photos.photo_file: MaxSize 10 MB → 50 MB. The app no longer
//     downscales photos; a full-resolution JPEG can exceed 10 MB.
//
// Down sets 10 MB again (existing larger files stay stored).
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

func phaseSPhotoLimitUp(app core.App) error {
	return phaseSSetPhotoMaxSize(app, phaseSPhotoMaxSize)
}

func phaseSPhotoLimitDown(app core.App) error {
	return phaseSSetPhotoMaxSize(app, phaseSPhotoLegacyMaxSize)
}

func init() {
	m.Register(phaseSPhotoLimitUp, phaseSPhotoLimitDown)
}
