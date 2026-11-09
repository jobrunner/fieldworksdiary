package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteOutput_RefusesExistingWithoutForce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin_labels.json")
	if err := os.WriteFile(path, []byte("curated"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	if err := writeOutput(path, []byte("generated"), false, &stderr); err == nil {
		t.Fatal("expected refusal without -force")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "curated" {
		t.Errorf("file overwritten: %q", got)
	}
}

func TestWriteOutput_ForceOverwritesWithWarning(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin_labels.json")
	if err := os.WriteFile(path, []byte("curated"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	if err := writeOutput(path, []byte("generated"), true, &stderr); err != nil {
		t.Fatalf("writeOutput: %v", err)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "generated" {
		t.Errorf("file = %q, want generated", got)
	}
	if !strings.Contains(stderr.String(), "hand-curated") {
		t.Errorf("missing warning, stderr = %q", stderr.String())
	}
}

func TestWriteOutput_NewFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "new.json")
	var stderr bytes.Buffer
	if err := writeOutput(path, []byte("generated"), false, &stderr); err != nil {
		t.Fatalf("writeOutput: %v", err)
	}
	if !strings.Contains(stderr.String(), "hand-curated") {
		t.Errorf("missing warning, stderr = %q", stderr.String())
	}
}
