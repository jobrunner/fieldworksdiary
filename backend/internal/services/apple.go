// Package services — Apple Identity-Token verifier for native
// Sign in with Apple (Phase R8).
//
// Verifies the Apple-issued identityToken (a JWT signed RS256 with a
// rotating Apple key) against the public JWKS at
// `https://appleid.apple.com/auth/keys`, with a one-hour cache. The
// `aud` claim must match one of the app's bundle ids (the native
// audience), the `iss` must be Apple, and `exp` must still be in
// the future. The caller is then trusted to upsert a PocketBase
// user by the stable `sub` claim.
package services

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

const (
	appleJWKSURL = "https://appleid.apple.com/auth/keys"
	appleIssuer  = "https://appleid.apple.com"
)

// AppleClaims is the subset of the identityToken payload we trust
// after verification. Apple sometimes ships `email_verified` as a
// stringly-typed JSON value, so we don't model it here — the email
// alone (when present) is enough to optionally link an existing
// password-user.
type AppleClaims struct {
	Email string `json:"email"`
	jwt.RegisteredClaims
}

// AppleVerifier checks identityToken validity. Construct via
// `NewAppleVerifier` and inject — it's safe to share across requests.
type AppleVerifier struct {
	// AllowedAudiences lists the iOS bundle ids the app may legitimately
	// produce identityTokens for (e.g. `org.fieldworksdiary.dev`).
	// A token whose `aud` is outside the list is rejected.
	AllowedAudiences []string

	// HTTPClient performs the JWKS fetch. Tests override this with a
	// httptest server.
	HTTPClient *http.Client

	// JWKSURL is the well-known endpoint to fetch keys from. Defaults
	// to Apple's; tests override to a local stub.
	JWKSURL string

	// JWKSTTL caps how long a fetched key-set stays cached.
	JWKSTTL time.Duration

	// Clock returns the current time; defaults to time.Now. Tests
	// override for deterministic exp/iat verification.
	Clock func() time.Time

	mu      sync.RWMutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

// NewAppleVerifier returns a verifier pre-wired for production Apple
// JWKS with the given allowed audiences (bundle ids).
func NewAppleVerifier(audiences []string) *AppleVerifier {
	return &AppleVerifier{
		AllowedAudiences: audiences,
		HTTPClient:       &http.Client{Timeout: 10 * time.Second},
		JWKSURL:          appleJWKSURL,
		JWKSTTL:          time.Hour,
		Clock:            time.Now,
	}
}

// Verify parses + validates an identityToken. Returns the trusted
// claims on success.
//
// jwt/v4 doesn't expose a TimeFunc on the parser, so we disable its
// built-in claim validation (`SkipClaimsValidation`) and do iss / aud
// / sub / exp / iat ourselves against `v.now()`. A 5-minute leeway on
// exp/iat absorbs the usual device clock skew.
func (v *AppleVerifier) Verify(ctx context.Context, tokenString string) (*AppleClaims, error) {
	parser := &jwt.Parser{
		ValidMethods:         []string{"RS256"},
		SkipClaimsValidation: true,
	}
	var claims AppleClaims
	_, err := parser.ParseWithClaims(tokenString, &claims, func(t *jwt.Token) (interface{}, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("apple: missing kid in token header")
		}
		return v.keyFor(ctx, kid)
	})
	if err != nil {
		return nil, fmt.Errorf("apple verify: %w", err)
	}
	if claims.Issuer != appleIssuer {
		return nil, fmt.Errorf("apple verify: issuer = %q, want %q", claims.Issuer, appleIssuer)
	}
	if claims.Subject == "" {
		return nil, errors.New("apple verify: missing sub")
	}
	if !v.audienceAllowed(claims.Audience) {
		return nil, fmt.Errorf("apple verify: audience %v not in allow-list", []string(claims.Audience))
	}
	now := v.now()
	const leeway = 5 * time.Minute
	if claims.ExpiresAt != nil && claims.ExpiresAt.Add(leeway).Before(now) {
		return nil, errors.New("apple verify: token expired")
	}
	if claims.IssuedAt != nil && claims.IssuedAt.After(now.Add(leeway)) {
		return nil, errors.New("apple verify: iat in the future")
	}
	return &claims, nil
}

func (v *AppleVerifier) now() time.Time {
	if v.Clock != nil {
		return v.Clock()
	}
	return time.Now()
}

func (v *AppleVerifier) audienceAllowed(aud jwt.ClaimStrings) bool {
	for _, a := range aud {
		for _, allow := range v.AllowedAudiences {
			if a == allow {
				return true
			}
		}
	}
	return false
}

func (v *AppleVerifier) keyFor(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	if k := v.cachedKey(kid); k != nil {
		return k, nil
	}
	if err := v.refresh(ctx); err != nil {
		return nil, err
	}
	if k := v.cachedKey(kid); k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("apple verify: kid %q not in JWKS", kid)
}

func (v *AppleVerifier) cachedKey(kid string) *rsa.PublicKey {
	v.mu.RLock()
	defer v.mu.RUnlock()
	if v.JWKSTTL > 0 && v.now().Sub(v.fetched) > v.JWKSTTL {
		return nil
	}
	return v.keys[kid]
}

type appleJWK struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func (v *AppleVerifier) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.JWKSURL, nil)
	if err != nil {
		return err
	}
	resp, err := v.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("apple jwks fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("apple jwks fetch: HTTP %d: %s", resp.StatusCode, string(body))
	}
	var set struct {
		Keys []appleJWK `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return fmt.Errorf("apple jwks decode: %w", err)
	}
	parsed := make(map[string]*rsa.PublicKey, len(set.Keys))
	for _, k := range set.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		pub, err := jwkToRSA(k.N, k.E)
		if err != nil {
			continue
		}
		parsed[k.Kid] = pub
	}
	v.mu.Lock()
	v.keys = parsed
	v.fetched = v.now()
	v.mu.Unlock()
	return nil
}

// jwkToRSA reconstructs the RSA public key from the base64url-encoded
// modulus and exponent fields a JWK carries.
func jwkToRSA(nB64, eB64 string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nB64)
	if err != nil {
		return nil, fmt.Errorf("decode n: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(eB64)
	if err != nil {
		return nil, fmt.Errorf("decode e: %w", err)
	}
	if len(eBytes) == 0 {
		return nil, errors.New("empty e")
	}
	e := 0
	for _, b := range eBytes {
		e = e<<8 | int(b)
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}, nil
}
