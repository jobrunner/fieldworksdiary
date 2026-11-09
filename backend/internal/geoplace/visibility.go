package geoplace

import "github.com/pocketbase/pocketbase/models"

// Placemark geocoding sources.
const (
	SourceBackendService = "backend_service"
	SourceManual         = "manual"
)

// IsShared reports whether a placemark row is a shared reference row:
// ownerless AND produced by the backend service. An ownerless manual row
// (owner cleared by a user deletion) is not shared.
func IsShared(rec *models.Record) bool {
	return rec != nil && rec.GetString("owner") == "" &&
		rec.GetString("geocoding_source") == SourceBackendService
}

// VisibleTo reports whether userID may see/reference the placemark row:
// it is shared or owned by userID. Single source of truth for the
// placemark visibility rule used by hooks, labels and export; the
// placemarks List/View rule (migration 1700000023) is its API-rule twin.
func VisibleTo(rec *models.Record, userID string) bool {
	if rec == nil {
		return false
	}
	if IsShared(rec) {
		return true
	}
	return userID != "" && rec.GetString("owner") == userID
}
