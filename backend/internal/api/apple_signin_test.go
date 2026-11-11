package api

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mett.io/fwd-backend/internal/testutil"

	"go.mett.io/fwd-backend/internal/services"

	"github.com/golang-jwt/jwt/v4"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// applesFixture: TestApp + a signing key + an echo router with the
// route mounted against a JWKS-stub verifier. Stays alive across
// multiple requests so post-conditions can hit the DB directly —
// avoids ApiScenario's per-scenario Cleanup that nils out `app`.
type applesFixture struct {
	app  *tests.TestApp
	priv *rsa.PrivateKey
	kid  string
	now  time.Time
	mux  http.Handler
}

func newApplesFixture(t *testing.T) *applesFixture {
	t.Helper()
	app := testutil.NewTestApp(t)
	// PocketBase's test fixture DB enables MFA on `users`; production
	// (fresh or upgraded from 0.22) has it off.
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	users.MFA.Enabled = false
	if err := app.Save(users); err != nil {
		t.Fatalf("disable mfa: %v", err)
	}

	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa key: %v", err)
	}
	const kid = "test-kid"
	nB64 := base64.RawURLEncoding.EncodeToString(priv.N.Bytes())
	eB64 := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes())
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]any{{"kid": kid, "kty": "RSA", "alg": "RS256", "n": nB64, "e": eB64}},
		})
	}))
	t.Cleanup(jwks.Close)

	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	v := services.NewAppleVerifier([]string{"org.fieldworksdiary.dev"})
	v.JWKSURL = jwks.URL
	v.Clock = func() time.Time { return now }

	// apis.NewRouter gives us PocketBase's router with its default
	// middlewares and error handling, so apis.NewBadRequestError /
	// NewUnauthorizedError map to proper status codes.
	r, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("NewRouter: %v", err)
	}
	bindAppleNativeSignIn(r, v)
	mux, err := r.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}

	app.ResetEventCalls()
	return &applesFixture{app: app, priv: priv, kid: kid, now: now, mux: mux}
}

func (f *applesFixture) signToken(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()
	if _, ok := claims["iss"]; !ok {
		claims["iss"] = "https://appleid.apple.com"
	}
	if _, ok := claims["aud"]; !ok {
		claims["aud"] = "org.fieldworksdiary.dev"
	}
	if _, ok := claims["exp"]; !ok {
		claims["exp"] = f.now.Add(10 * time.Minute).Unix()
	}
	if _, ok := claims["iat"]; !ok {
		claims["iat"] = f.now.Add(-1 * time.Minute).Unix()
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = f.kid
	signed, err := tok.SignedString(f.priv)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signed
}

// post issues a single request against the mounted route and returns
// the response. App stays alive for follow-up DB assertions.
func (f *applesFixture) post(t *testing.T, body any) (int, string) {
	t.Helper()
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/auth/apple-native", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	f.mux.ServeHTTP(rec, req)
	respBody, _ := io.ReadAll(rec.Body)
	return rec.Code, string(respBody)
}

func TestAppleNativeSignIn_CreatesNewUser(t *testing.T) {
	f := newApplesFixture(t)
	token := f.signToken(t, jwt.MapClaims{
		"sub":   "001234.fresh-user",
		"email": "fresh@example.com",
	})

	status, body := f.post(t, map[string]string{"identity_token": token})
	if status != http.StatusOK {
		t.Fatalf("status = %d, body = %s", status, body)
	}
	for _, want := range []string{`"token":`, `"record":`, `"email":"fresh@example.com"`} {
		if !strings.Contains(body, want) {
			t.Errorf("response missing %q\nbody = %s", want, body)
		}
	}
	rec, err := f.app.FindAuthRecordByEmail("users", "fresh@example.com")
	if err != nil {
		t.Fatalf("find user: %v", err)
	}
	if rec.GetString("apple_user_id") != "001234.fresh-user" {
		t.Errorf("apple_user_id = %q", rec.GetString("apple_user_id"))
	}
	if !rec.Verified() {
		t.Errorf("new Apple user should be verified")
	}
}

func TestAppleNativeSignIn_IsIdempotentOnSameSub(t *testing.T) {
	f := newApplesFixture(t)
	token := f.signToken(t, jwt.MapClaims{
		"sub":   "001234.repeat-user",
		"email": "repeat@example.com",
	})

	if status, body := f.post(t, map[string]string{"identity_token": token}); status != http.StatusOK {
		t.Fatalf("first: status = %d body = %s", status, body)
	}
	firstID := userIDForSub(t, f.app, "001234.repeat-user")

	if status, body := f.post(t, map[string]string{"identity_token": token}); status != http.StatusOK {
		t.Fatalf("second: status = %d body = %s", status, body)
	}
	secondID := userIDForSub(t, f.app, "001234.repeat-user")
	if firstID != secondID {
		t.Errorf("re-sign-in created a different user: %s vs %s", firstID, secondID)
	}

	all, _ := f.app.FindRecordsByFilter(
		"users", "apple_user_id = {:s}", "", 0, 0,
		map[string]any{"s": "001234.repeat-user"},
	)
	if len(all) != 1 {
		t.Errorf("expected 1 user, got %d", len(all))
	}
}

func TestAppleNativeSignIn_LinksToExistingEmailUser(t *testing.T) {
	f := newApplesFixture(t)
	existing := seedPasswordUser(t, f.app, "link-me@example.com")

	token := f.signToken(t, jwt.MapClaims{
		"sub":   "001234.linker",
		"email": "link-me@example.com",
	})
	if status, body := f.post(t, map[string]string{"identity_token": token}); status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, body)
	}
	reloaded, err := f.app.FindRecordById("users", existing.Id)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if reloaded.GetString("apple_user_id") != "001234.linker" {
		t.Errorf("apple_user_id not attached to existing user (got %q)",
			reloaded.GetString("apple_user_id"))
	}
}

func TestAppleNativeSignIn_RejectsEmptyToken(t *testing.T) {
	f := newApplesFixture(t)
	status, body := f.post(t, map[string]string{"identity_token": ""})
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d (want 400), body = %s", status, body)
	}
	if !strings.Contains(strings.ToLower(body), "identity_token") {
		t.Errorf("body should mention identity_token: %s", body)
	}
}

func TestAppleNativeSignIn_RejectsInvalidToken(t *testing.T) {
	f := newApplesFixture(t)
	status, body := f.post(t, map[string]string{"identity_token": "not-a-jwt"})
	if status != http.StatusUnauthorized {
		t.Fatalf("status = %d (want 401), body = %s", status, body)
	}
	if !strings.Contains(body, "Apple identity token is invalid.") {
		t.Errorf("body should generic-reject: %s", body)
	}
}

func TestAppleNativeSignIn_RejectsWrongAudience(t *testing.T) {
	f := newApplesFixture(t)
	token := f.signToken(t, jwt.MapClaims{
		"sub": "001234.foreign-bundle",
		"aud": "com.evil.app",
	})
	status, _ := f.post(t, map[string]string{"identity_token": token})
	if status != http.StatusUnauthorized {
		t.Fatalf("status = %d (want 401)", status)
	}
}

func userIDForSub(t *testing.T, app *tests.TestApp, sub string) string {
	t.Helper()
	rec, err := app.FindFirstRecordByFilter("users",
		"apple_user_id = {:s}", map[string]any{"s": sub})
	if err != nil {
		t.Fatalf("find by sub: %v", err)
	}
	return rec.Id
}

func seedPasswordUser(t *testing.T, app *tests.TestApp, email string) *core.Record {
	t.Helper()
	coll, _ := app.FindCollectionByNameOrId("users")
	rec := core.NewRecord(coll)
	rec.SetEmail(email)
	rec.Set("username", "pre_"+strings.ReplaceAll(t.Name(), "/", "_"))
	rec.SetPassword("test1234password")
	rec.SetVerified(true)
	if err := app.SaveNoValidate(rec); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return rec
}
