package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/security"
)

// legacyToken builds a token exactly like PocketBase 0.22 issued record
// auth tokens: claims id/type=authRecord/collectionId, HS256 signed with
// tokenKey + collection auth secret (the 0.23 upgrade keeps the old
// recordAuthToken secret there).
func legacyToken(t *testing.T, user *core.Record, typ, secretSuffix string, dur time.Duration) string {
	t.Helper()
	tok, err := security.NewJWT(jwt.MapClaims{
		"id":           user.Id,
		"type":         typ,
		"collectionId": user.Collection().Id,
	}, user.TokenKey()+user.Collection().AuthToken.Secret+secretSuffix, dur)
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	return tok
}

func TestLegacyAuthToken(t *testing.T) {
	for _, c := range []struct {
		name   string
		token  func(t *testing.T, u *core.Record) string
		status int
	}{
		{"valid 0.22 token accepted", func(t *testing.T, u *core.Record) string {
			return legacyToken(t, u, "authRecord", "", time.Hour)
		}, http.StatusOK},
		{"wrong signature rejected", func(t *testing.T, u *core.Record) string {
			return legacyToken(t, u, "authRecord", "x", time.Hour)
		}, http.StatusNotFound},
		{"expired token rejected", func(t *testing.T, u *core.Record) string {
			return legacyToken(t, u, "authRecord", "", -time.Hour)
		}, http.StatusNotFound},
		{"other legacy type ignored", func(t *testing.T, u *core.Record) string {
			return legacyToken(t, u, "admin", "", time.Hour)
		}, http.StatusNotFound},
		{"regular token still works", func(t *testing.T, u *core.Record) string {
			tok, err := u.NewAuthToken()
			if err != nil {
				t.Fatal(err)
			}
			return tok
		}, http.StatusOK},
	} {
		t.Run(c.name, func(t *testing.T) {
			app := setupTestApp(t)
			user := makeUser(t, app, "legacy@example.com")
			scenario := tests.ApiScenario{
				Name:                  c.name,
				Method:                http.MethodGet,
				URL:                   "/api/collections/users/records/" + user.Id,
				Headers:               map[string]string{"Authorization": c.token(t, user)},
				ExpectedStatus:        c.status,
				ExpectedContent:       []string{`"`},
				TestAppFactory:        func(testing.TB) *tests.TestApp { return app },
				DisableTestAppCleanup: true,
				BeforeTestFunc: func(_ testing.TB, _ *tests.TestApp, e *core.ServeEvent) {
					e.Router.Bind(legacyAuthTokenMiddleware())
				},
			}
			scenario.Test(t)
		})
	}
}
