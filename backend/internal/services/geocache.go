// Package services holds wrappers around the external Docker-Maschine
// services (labelloc, MTB) plus a write-through cache for their
// responses. Wrappers retry transient failures, time out aggressively,
// and never bubble errors up to the caller in a way that would kill
// the originating sample insert — the worst case is "no enrichment
// for now, retry next time".
package services

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
)

// DefaultCacheTTL is how long a cached payload stays valid. Beyond
// that we evict and re-fetch.
const DefaultCacheTTL = 7 * 24 * time.Hour

// Geocache reads and writes the `geocache` collection. Keys are
// service-scoped (so labelloc and mtb can share the lat/lon space
// without collisions).
type Geocache struct {
	Dao *daos.Dao
	TTL time.Duration
}

// CoordinateKey turns (lat, lon, lang) into a stable cache key.
// Coordinates are rounded to 5 decimal places (~1.1 m) so semantically
// identical lookups land on the same row.
func CoordinateKey(lat, lon float64, lang string) string {
	raw := fmt.Sprintf("%.5f|%.5f|%s", lat, lon, lang)
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// Get returns the cached payload bytes, or sql.ErrNoRows if absent or
// expired.
func (c *Geocache) Get(service, key string) ([]byte, error) {
	rec, err := c.Dao.FindFirstRecordByFilter(
		"geocache",
		"service = {:svc} && key = {:key}",
		dbx.Params{"svc": service, "key": key},
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	cachedAt := rec.GetDateTime("cached_at").Time()
	if time.Since(cachedAt) > c.ttl() {
		return nil, sql.ErrNoRows
	}
	return []byte(rec.GetString("payload")), nil
}

// Put writes (or refreshes) a cache entry.
func (c *Geocache) Put(service, key string, payload []byte) error {
	coll, err := c.Dao.FindCollectionByNameOrId("geocache")
	if err != nil {
		return err
	}

	rec, err := c.Dao.FindFirstRecordByFilter(
		"geocache",
		"service = {:svc} && key = {:key}",
		dbx.Params{"svc": service, "key": key},
	)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if rec == nil {
		rec = models.NewRecord(coll)
		rec.Set("service", service)
		rec.Set("key", key)
	}
	rec.Set("payload", string(payload))
	rec.Set("cached_at", time.Now().UTC())
	return c.Dao.SaveRecord(rec)
}

func (c *Geocache) ttl() time.Duration {
	if c.TTL == 0 {
		return DefaultCacheTTL
	}
	return c.TTL
}
