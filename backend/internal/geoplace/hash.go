package geoplace

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"go.mett.io/fwd-backend/internal/adminlabels"
	"golang.org/x/text/unicode/norm"
)

// DedupHash identifies a place for deduplication: SHA-256 (hex) over the
// "|"-joined values CountryISO, then for every tier in adminlabels.Tiers
// order Name, Native and Level (decimal string, 0 as "0"), then Island,
// MountainRange, Mountain. Text values are trimmed, NFC normalized and
// lowercased; empty values stay as empty fields so positions are stable.
// Native and Level are part of the hash so a client cannot poison a shared
// row by sending the same names with invented native names or levels.
func (p Place) DedupHash() string {
	parts := make([]string, 0, 4+3*len(adminlabels.Tiers))
	parts = append(parts, normHashPart(p.CountryISO))
	for _, t := range adminlabels.Tiers {
		v := p.Admin[t]
		parts = append(parts, normHashPart(v.Name), normHashPart(v.Native), strconv.Itoa(v.Level))
	}
	parts = append(parts, normHashPart(p.Island), normHashPart(p.MountainRange), normHashPart(p.Mountain))
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:])
}

func normHashPart(s string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(s)))
}
