package geoplace

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"golang.org/x/text/unicode/norm"
)

// DedupHash identifies a place for deduplication: SHA-256 (hex) over the
// "|"-joined values CountryISO, the Name of every tier in adminlabels.Tiers
// order, Island, MountainRange, Mountain. Each value is trimmed, NFC
// normalized and lowercased; empty values stay as empty fields so positions
// are stable.
func (p Place) DedupHash() string {
	parts := make([]string, 0, 4+len(adminlabels.Tiers))
	parts = append(parts, p.CountryISO)
	for _, t := range adminlabels.Tiers {
		parts = append(parts, p.Admin[t].Name)
	}
	parts = append(parts, p.Island, p.MountainRange, p.Mountain)
	for i, v := range parts {
		parts[i] = strings.ToLower(norm.NFC.String(strings.TrimSpace(v)))
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:])
}
