package migrations

import (
	"strings"
	"testing"
)

func TestAppleUserIDColumnIsPresent(t *testing.T) {
	app := setupTestApp(t)
	users, err := app.Dao().FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("find users: %v", err)
	}
	if users.Schema.GetFieldByName("apple_user_id") == nil {
		t.Fatal("users.apple_user_id missing after R8 migration")
	}
	found := false
	for _, stmt := range users.Indexes {
		if strings.Contains(stmt, "idx_users_apple_user_id") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("idx_users_apple_user_id missing; indexes = %v", users.Indexes)
	}
}
