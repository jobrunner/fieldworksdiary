// Phase R8 — native Sign in with Apple endpoint.
//
// The iOS app's ASAuthorizationController flow yields an Apple
// `identityToken` (a JWT) and a stable per-(team,user) `sub`. We
// can't ride PocketBase's built-in `auth-with-oauth2` flow with
// those: that one is the web-OAuth2 code-exchange path (PKCE
// codeVerifier + redirect_uri must match the authUrl), and a native
// authorizationCode satisfies neither — plus its `aud` is the app's
// bundle id, not the configured Services ID.
//
// So instead, this route verifies the identityToken server-side
// against Apple's JWKS, looks up (or creates) a `users` record by
// `apple_user_id = <sub>`, and returns a PocketBase auth token in
// the same JSON shape the other auth endpoints do — so the iOS
// `AuthResponse` decoder stays unchanged.
package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"

	"go.mett.io/fwd-backend/internal/services"

	"github.com/labstack/echo/v5"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
)

// RegisterAppleNativeSignIn wires `POST /api/auth/apple-native`.
// Call from `main.go` with a verifier configured for the running
// app's bundle ids.
func RegisterAppleNativeSignIn(app core.App, verifier *services.AppleVerifier) {
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		e.Router.POST("/api/auth/apple-native", func(c echo.Context) error {
			return handleAppleNativeSignIn(app, c, verifier)
		})
		return nil
	})
}

type appleNativeRequest struct {
	IdentityToken string `json:"identity_token"`
}

func handleAppleNativeSignIn(app core.App, c echo.Context, verifier *services.AppleVerifier) error {
	var req appleNativeRequest
	if err := c.Bind(&req); err != nil {
		return apis.NewBadRequestError("Invalid request body.", err)
	}
	if req.IdentityToken == "" {
		return apis.NewBadRequestError("identity_token is required.", nil)
	}
	claims, err := verifier.Verify(c.Request().Context(), req.IdentityToken)
	if err != nil {
		// Don't leak verification internals (kid, signature reason, …)
		// to clients; the log keeps the detail for diagnostics.
		app.Logger().Warn(
			"apple-signin: verify failed",
			slog.String("err", err.Error()),
		)
		return apis.NewUnauthorizedError("Apple identity token is invalid.", nil)
	}

	user, created, err := upsertAppleUser(app.Dao(), claims)
	if err != nil {
		app.Logger().Error(
			"apple-signin: user upsert failed",
			slog.String("err", err.Error()),
			slog.String("apple_sub", truncate(claims.Subject)),
		)
		return apis.NewApiError(http.StatusInternalServerError, "could not link Apple identity", err)
	}
	app.Logger().Info(
		"apple-signin: ok",
		slog.String("user_id", user.Id),
		slog.String("apple_sub", truncate(claims.Subject)),
		slog.Bool("created", created),
	)
	return apis.RecordAuthResponse(app, c, user, nil)
}

// upsertAppleUser resolves the Apple `sub` to a PB user, creating
// or linking as needed. Returns the user and whether it was newly
// created (for logging only).
//
// Lookup order:
//
//  1. exact match on `apple_user_id`. Stable identity → same user.
//  2. if an email is in the token, match it against existing
//     password-users and attach `apple_user_id` to that row.
//  3. otherwise create a fresh `users` record.
func upsertAppleUser(dao *daos.Dao, claims *services.AppleClaims) (*models.Record, bool, error) {
	if rec, err := findUserByAppleSub(dao, claims.Subject); err == nil && rec != nil {
		return rec, false, nil
	}
	if claims.Email != "" {
		if rec, _ := dao.FindAuthRecordByEmail("users", claims.Email); rec != nil {
			rec.Set("apple_user_id", claims.Subject)
			if err := dao.SaveRecord(rec); err != nil {
				return nil, false, err
			}
			return rec, false, nil
		}
	}
	coll, err := dao.FindCollectionByNameOrId("users")
	if err != nil {
		return nil, false, err
	}
	email := claims.Email
	if email == "" {
		// Apple withholds the email after the first sign-in unless the
		// user explicitly chose to share it. Synthesize a placeholder
		// that's unique per Apple sub so PB's required-email constraint
		// is satisfied without leaking anything.
		email = claims.Subject + "@apple.local"
	}
	pwd, err := randomPassword()
	if err != nil {
		return nil, false, err
	}
	rec := models.NewRecord(coll)
	if err := rec.SetEmail(email); err != nil {
		return nil, false, err
	}
	if err := rec.SetUsername("apple_" + claims.Subject); err != nil {
		return nil, false, err
	}
	if err := rec.SetPassword(pwd); err != nil {
		return nil, false, err
	}
	if err := rec.SetVerified(true); err != nil {
		return nil, false, err
	}
	rec.Set("apple_user_id", claims.Subject)
	if err := dao.SaveRecord(rec); err != nil {
		return nil, false, err
	}
	return rec, true, nil
}

func findUserByAppleSub(dao *daos.Dao, sub string) (*models.Record, error) {
	if sub == "" {
		return nil, errors.New("empty sub")
	}
	return dao.FindFirstRecordByFilter(
		"users",
		"apple_user_id = {:s}",
		dbx.Params{"s": sub},
	)
}

// randomPassword returns a 32-byte hex string. The user never needs
// to type it — Apple is the authoritative auth path — but PB's users
// collection requires the field to be set on create.
func randomPassword() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// truncate keeps the first 8 chars of an opaque id for log lines so
// the full Apple sub never lands in plaintext (treat it like PII).
func truncate(s string) string {
	if len(s) <= 8 {
		return s
	}
	return s[:8] + "…"
}
