package geoplace_test

import (
	"testing"

	"go.mett.io/fwd-backend/internal/geoplace"
)

// After migration 1700000027 the legacy columns are gone; the mapping
// must be a no-op instead of failing on the unknown filter fields.
func TestMapLegacyManualPlacemarks_NoopWithoutLegacyColumns(t *testing.T) {
	app := newStoreApp(t)
	n, err := geoplace.MapLegacyManualPlacemarks(app.Dao(), nil)
	if err != nil || n != 0 {
		t.Fatalf("got (%d, %v), want (0, nil)", n, err)
	}
}
