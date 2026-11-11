// Compatibility for auth tokens issued by PocketBase 0.22.
//
// 0.22 signed record auth tokens with the claim `type: "authRecord"`;
// 0.23+ only accepts `type: "auth"`. The secret did not change: the
// 0.23 upgrade migration copies the old `recordAuthToken` secret into
// the `users` collection, and the signature still uses the record's
// tokenKey plus that secret. Without this shim every iOS client that
// is logged in at deploy time would get 401 on its next sync and its
// token refresh would fail too (the refresh needs a valid token), i.e.
// a forced re-login for everybody.
//
// The middleware accepts such a legacy token exactly like 0.22 did
// (signature + expiry), so the client keeps working and its next
// `auth-refresh` returns a regular 0.23+ token. Legacy tokens expire
// after the old auth token duration (14 days by default), after that
// the shim is dead code and can be removed (see ADR 0008).
package api

import (
	"log/slog"
	"strings"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/hook"
	"github.com/pocketbase/pocketbase/tools/security"
)

const (
	legacyTokenType         = "authRecord"
	legacyTokenMiddlewareID = "fwdLegacyAuthToken" //nolint:gosec // G101: hook id, not a credential
)

// RegisterLegacyAuthTokens binds the legacy token middleware globally.
func RegisterLegacyAuthTokens(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.Bind(legacyAuthTokenMiddleware())
		return se.Next()
	})
}

// legacyAuthTokenMiddleware runs right before PocketBase's own
// loadAuthToken middleware, which skips requests whose e.Auth is
// already set.
func legacyAuthTokenMiddleware() *hook.Handler[*core.RequestEvent] {
	return &hook.Handler[*core.RequestEvent]{
		Id:       legacyTokenMiddlewareID,
		Priority: apis.DefaultLoadAuthTokenMiddlewarePriority - 1,
		Func: func(e *core.RequestEvent) error {
			if e.Auth == nil {
				if rec := findLegacyAuthRecord(e.App, authTokenFromRequest(e)); rec != nil {
					e.Auth = rec
					e.App.Logger().Debug("legacy auth token accepted",
						slog.String("user_id", rec.Id))
				}
			}
			return e.Next()
		},
	}
}

// authTokenFromRequest mirrors PocketBase: the Authorization header,
// optionally with a "Bearer " prefix.
func authTokenFromRequest(e *core.RequestEvent) string {
	token := e.Request.Header.Get("Authorization")
	if len(token) > 7 && strings.EqualFold(token[:7], "Bearer ") {
		return token[7:]
	}
	return token
}

// findLegacyAuthRecord returns the auth record of a valid (signature and
// expiry checked) 0.22 record auth token, otherwise nil.
func findLegacyAuthRecord(app core.App, token string) *core.Record {
	if token == "" {
		return nil
	}
	claims, err := security.ParseUnverifiedJWT(token)
	if err != nil {
		return nil
	}
	if typ, _ := claims[core.TokenClaimType].(string); typ != legacyTokenType {
		return nil
	}
	id, _ := claims[core.TokenClaimId].(string)
	collectionID, _ := claims[core.TokenClaimCollectionId].(string)
	if id == "" || collectionID == "" {
		return nil
	}
	record, err := app.FindRecordById(collectionID, id)
	if err != nil || !record.Collection().IsAuth() || record.IsSuperuser() {
		return nil
	}
	if _, err := security.ParseJWT(token, record.TokenKey()+record.Collection().AuthToken.Secret); err != nil {
		return nil
	}
	return record
}
