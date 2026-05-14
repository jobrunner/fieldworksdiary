package services

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRepairDoubleEncodedUTF8_FixesMojibake(t *testing.T) {
	// "Würzburg" mojibake'd: every "ü" → 0xC3 0x83 0xC2 0xBC.
	mojibake := []byte("W\xC3\x83\xC2\xBCrzburg")
	want := "Würzburg"
	got := string(repairDoubleEncodedUTF8(mojibake))
	if got != want {
		t.Errorf("got %q, want %q (bytes: % X)", got, want, []byte(got))
	}
}

func TestRepairDoubleEncodedUTF8_AllUmlauts(t *testing.T) {
	cases := map[string]string{
		"\xC3\x83\xC2\x84": "Ä",
		"\xC3\x83\xC2\x96": "Ö",
		"\xC3\x83\xC2\x9C": "Ü",
		"\xC3\x83\xC2\xA4": "ä",
		"\xC3\x83\xC2\xB6": "ö",
		"\xC3\x83\xC2\xBC": "ü",
		"\xC3\x83\xC2\x9F": "ß",
	}
	for in, want := range cases {
		got := string(repairDoubleEncodedUTF8([]byte(in)))
		if got != want {
			t.Errorf("input % X: got %q, want %q", []byte(in), got, want)
		}
	}
}

func TestRepairDoubleEncodedUTF8_LeavesCleanInputAlone(t *testing.T) {
	clean := []byte("Würzburg, Bayern, Deutschland")
	got := repairDoubleEncodedUTF8(clean)
	if string(got) != string(clean) {
		t.Errorf("clean input changed: %q -> %q", clean, got)
	}
}

func TestRepairDoubleEncodedUTF8_PreservesAscii(t *testing.T) {
	ascii := []byte("plain ascii without any special chars")
	got := repairDoubleEncodedUTF8(ascii)
	if string(got) != string(ascii) {
		t.Errorf("ascii changed: %q -> %q", ascii, got)
	}
}

func TestRepairDoubleEncodedUTF8_MixedContent(t *testing.T) {
	// Mix of clean and mojibake'd content.
	in := []byte("Bayern, W\xC3\x83\xC2\xBCrzburg, Region")
	want := "Bayern, Würzburg, Region"
	got := string(repairDoubleEncodedUTF8(in))
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLabellocLookup_ParsesUpstreamShape(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/location" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"result":{"country":"Deutschland","countryIso":"DE","adminArea":"Bayern","adminArea2":"Unterfranken","locality":"Würzburg","locationDescription":"DE, Bayern, Würzburg"},"status":{"code":0,"message":"success"}}`))
	}))
	defer srv.Close()

	client := &Labelloc{BaseURL: srv.URL, MaxRetries: 1}
	got, err := client.Lookup(context.Background(), 49.79, 9.95, "de")
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got.Country != "Deutschland" || got.Locality != "Würzburg" {
		t.Errorf("unexpected response: %+v", got)
	}
}

func TestLabellocLookup_RetriesOn5xx(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 2 {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte(`{"result":{"country":"X"},"status":{"code":0}}`))
	}))
	defer srv.Close()

	client := &Labelloc{BaseURL: srv.URL, MaxRetries: 3}
	got, err := client.Lookup(context.Background(), 0, 0, "de")
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got.Country != "X" {
		t.Errorf("expected retry to succeed, got %+v", got)
	}
	if calls != 2 {
		t.Errorf("expected 2 attempts, got %d", calls)
	}
}

func TestLabellocLookup_DoesNotRetry4xx(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Error(w, "bad input", http.StatusBadRequest)
	}))
	defer srv.Close()

	client := &Labelloc{BaseURL: srv.URL, MaxRetries: 5}
	_, err := client.Lookup(context.Background(), 0, 0, "de")
	if err == nil {
		t.Fatal("expected error on 4xx")
	}
	if calls != 1 {
		t.Errorf("expected single attempt on 4xx, got %d", calls)
	}
}
