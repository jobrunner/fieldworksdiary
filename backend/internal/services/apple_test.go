package services

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

// jwksProbe spins up a httptest server that returns a single RSA
// public key under the requested kid. Returns the matching private
// key for signing test tokens.
func jwksProbe(t *testing.T, kid string) (*httptest.Server, *rsa.PrivateKey) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	nB64 := base64.RawURLEncoding.EncodeToString(priv.N.Bytes())
	eB64 := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]any{{"kid": kid, "kty": "RSA", "alg": "RS256", "n": nB64, "e": eB64}},
		})
	}))
	t.Cleanup(srv.Close)
	return srv, priv
}

func signToken(t *testing.T, priv *rsa.PrivateKey, kid string, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	signed, err := tok.SignedString(priv)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signed
}

func newAppleTestVerifier(srv *httptest.Server, audiences []string, now time.Time) *AppleVerifier {
	v := NewAppleVerifier(audiences)
	v.JWKSURL = srv.URL
	v.Clock = func() time.Time { return now }
	return v
}

func TestAppleVerifier_HappyPath(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	tokenStr := signToken(t, priv, "k1", jwt.MapClaims{
		"iss":   "https://appleid.apple.com",
		"aud":   "org.fieldworksdiary.dev",
		"sub":   "001234.abc.dev",
		"email": "jo@example.com",
		"iat":   now.Add(-1 * time.Minute).Unix(),
		"exp":   now.Add(10 * time.Minute).Unix(),
	})

	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	got, err := v.Verify(context.Background(), tokenStr)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if got.Subject != "001234.abc.dev" {
		t.Errorf("sub = %q, want 001234.abc.dev", got.Subject)
	}
	if got.Email != "jo@example.com" {
		t.Errorf("email = %q", got.Email)
	}
}

func TestAppleVerifier_RejectsWrongAudience(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	tokenStr := signToken(t, priv, "k1", jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "com.evil.app",
		"sub": "x",
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err == nil {
		t.Fatal("expected audience rejection")
	}
}

func TestAppleVerifier_RejectsWrongIssuer(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	tokenStr := signToken(t, priv, "k1", jwt.MapClaims{
		"iss": "https://attacker.example",
		"aud": "org.fieldworksdiary.dev",
		"sub": "x",
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err == nil {
		t.Fatal("expected issuer rejection")
	}
}

func TestAppleVerifier_RejectsExpired(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	tokenStr := signToken(t, priv, "k1", jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "org.fieldworksdiary.dev",
		"sub": "x",
		"iat": now.Add(-2 * time.Hour).Unix(),
		"exp": now.Add(-1 * time.Hour).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err == nil {
		t.Fatal("expected expired rejection")
	}
}

func TestAppleVerifier_RejectsUnknownKid(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	// Sign with priv but claim a different kid → JWKS lookup fails.
	tokenStr := signToken(t, priv, "k2", jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "org.fieldworksdiary.dev",
		"sub": "x",
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err == nil {
		t.Fatal("expected kid-mismatch rejection")
	}
}

func TestAppleVerifier_RejectsBadSignature(t *testing.T) {
	srv, _ := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	// Sign with a DIFFERENT key than the one the JWKS publishes.
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	tokenStr := signToken(t, other, "k1", jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "org.fieldworksdiary.dev",
		"sub": "x",
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{"org.fieldworksdiary.dev"}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err == nil {
		t.Fatal("expected bad-signature rejection")
	}
}

func TestAppleVerifier_AcceptsAnyAllowedAudience(t *testing.T) {
	srv, priv := jwksProbe(t, "k1")
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	tokenStr := signToken(t, priv, "k1", jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "org.fieldworksdiary.prod",
		"sub": "x",
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	v := newAppleTestVerifier(srv, []string{
		"org.fieldworksdiary.dev",
		"org.fieldworksdiary.staging",
		"org.fieldworksdiary.prod",
	}, now)
	if _, err := v.Verify(context.Background(), tokenStr); err != nil {
		t.Fatalf("verify: %v", err)
	}
}
