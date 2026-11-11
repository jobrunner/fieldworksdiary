package adminlabels

import (
	"bytes"
	"os"
	"testing"
)

func TestDefault_HasAll77Countries(t *testing.T) {
	if got := len(Default().Countries); got != 77 {
		t.Fatalf("countries = %d, want 77", got)
	}
}

func TestColumn_DE(t *testing.T) {
	tb := Default()
	if c, ok := tb.Column("DE", 8); !ok || c != "admin_municipality" {
		t.Errorf("DE/8 = %q,%v", c, ok)
	}
	if c, ok := tb.Column("DE", 4); !ok || c != "admin_state" {
		t.Errorf("DE/4 = %q,%v", c, ok)
	}
}

func TestColumn_CollisionLowestLevelWins(t *testing.T) {
	tb := Default()
	if c, ok := tb.Column("DE", 10); !ok || c != "admin_submunicipality" {
		t.Errorf("DE/10 = %q,%v", c, ok)
	}
	if c, ok := tb.Column("DE", 11); !ok || c != "" {
		t.Errorf("DE/11 = %q,%v, want known-but-unstored", c, ok)
	}
}

func TestColumn_UnknownCountry(t *testing.T) {
	if c, ok := Default().Column("XX", 8); ok || c != "" {
		t.Errorf("XX/8 = %q,%v", c, ok)
	}
}

func TestTerm(t *testing.T) {
	tb := Default()
	if tb.Term("DE", 4) == "" {
		t.Error("DE/4 term empty")
	}
	if tb.Term("XX", 4) != "" {
		t.Error("unknown country should give empty term")
	}
}

func TestCopyMatchesShared(t *testing.T) {
	a, err := os.ReadFile("admin_labels.json")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile("../../../shared/admin-labels/admin_labels.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("backend copy differs from shared/admin-labels; run scripts/sync-admin-labels.sh")
	}
}
