package conditions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/tabularius/internal/services"
	"go.mett.io/tabularius/internal/testutil"
	_ "go.mett.io/tabularius/migrations"
)

func fixture(t *testing.T, name string) *services.TempusResponse {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "testdata", "tempus", name))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var resp services.TempusResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return &resp
}

var (
	past      = time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	allKinds  = []string{"aggregate", "bioclim", "dewpoint", "moon", "sun", "weather"}
	pastFetch = past.Add(30 * 24 * time.Hour)
)

func TestFromTempus_PastAllOk(t *testing.T) {
	r := FromTempus(fixture(t, "query_past_all_ok.json"), past, pastFetch)
	if r.Status != StatusFinal {
		t.Errorf("status = %q", r.Status)
	}
	if !r.RetryAt.IsZero() {
		t.Errorf("retryAt = %s, want zero", r.RetryAt)
	}
	if !r.QueriedFor.Equal(past) || !r.FetchedAt.Equal(pastFetch) {
		t.Errorf("queriedFor %s, fetchedAt %s", r.QueriedFor, r.FetchedAt)
	}
	if !reflect.DeepEqual(r.Kinds, allKinds) {
		t.Errorf("kinds = %v", r.Kinds)
	}
	want := map[string]any{
		"weather_temperature_c":    16.0,
		"weather_humidity_pct":     85.0,
		"weather_dew_point_c":      13.5,
		"weather_precipitation_mm": 1.4,
		"weather_wind_speed_kmh":   7.4,
		"weather_cloud_cover_pct":  100.0,
		"weather_code":             61.0,
		"precipitation_24h_mm":     34.0,
		"precipitation_72h_mm":     62.5,
		"precipitation_120h_mm":    62.7,
		"day_temperature_min_c":    14.2,
		"day_temperature_max_c":    18.5,
		"day_temperature_mean_c":   17.3,
		"climate_koppen_code":      "Dfb",
		"climate_altitudinal_belt": "submontan-kollin",
		"sunrise":                  time.Date(2026, 7, 1, 3, 16, 45, 0, time.UTC),
		"sunset":                   time.Date(2026, 7, 1, 19, 17, 30, 0, time.UTC),
		"moon_phase":               "Vollmond",
		"moon_illumination_pct":    97.89,
	}
	if len(r.Values) != len(want) {
		t.Errorf("values has %d entries, want %d: %v", len(r.Values), len(want), r.Values)
	}
	for k, v := range want {
		got, ok := r.Values[k]
		if !ok {
			t.Errorf("value %s missing", k)
			continue
		}
		if tv, isTime := v.(time.Time); isTime {
			if gt, _ := got.(time.Time); !gt.Equal(tv) {
				t.Errorf("%s = %v, want %v", k, got, v)
			}
			continue
		}
		if got != v {
			t.Errorf("%s = %v, want %v", k, got, v)
		}
	}
	if len(r.Features) != 6 {
		t.Fatalf("features = %d", len(r.Features))
	}
	for _, f := range r.Features {
		if !strings.HasPrefix(f.SourceID, FeatureSourcePrefix) || f.SourceID != FeatureSourcePrefix+f.Layer {
			t.Errorf("source id %q, layer %q", f.SourceID, f.Layer)
		}
		if f.SourceName != "Tempus" || len(f.License) == 0 || len(f.Properties) == 0 {
			t.Errorf("feature %s incomplete", f.SourceID)
		}
	}
}

func TestFromTempus_RecentIsProvisionalWithRetryAfter(t *testing.T) {
	fetched := past.Add(3 * time.Hour)
	r := FromTempus(fixture(t, "query_recent_weather_unavailable.json"), past, fetched)
	if r.Status != StatusProvisional {
		t.Errorf("status = %q", r.Status)
	}
	if !r.RetryAt.Equal(fetched.Add(2 * time.Hour)) {
		t.Errorf("retryAt = %s", r.RetryAt)
	}
	if !reflect.DeepEqual(r.Kinds, []string{"aggregate", "bioclim", "moon", "sun"}) {
		t.Errorf("kinds = %v", r.Kinds)
	}
	if _, ok := r.Values["weather_temperature_c"]; ok {
		t.Error("weather value present without a weather feature")
	}
}

// Unavailable without a retryAfter hint is retried after an hour.
func TestFromTempus_UnavailableWithoutHintRetriesAfterOneHour(t *testing.T) {
	resp := fixture(t, "query_recent_weather_unavailable.json")
	for i := range resp.Providers {
		resp.Providers[i].RetryAfter = ""
	}
	fetched := past.Add(3 * time.Hour)
	r := FromTempus(resp, past, fetched)
	if !r.RetryAt.Equal(fetched.Add(time.Hour)) {
		t.Errorf("retryAt = %s", r.RetryAt)
	}
}

// Old enough to be final, but a provider is still unavailable.
func TestFromTempus_OldButUnavailableStaysProvisional(t *testing.T) {
	r := FromTempus(fixture(t, "query_recent_weather_unavailable.json"), past, pastFetch)
	if r.Status != StatusProvisional || !r.RetryAt.Equal(pastFetch.Add(2*time.Hour)) {
		t.Errorf("status %q, retryAt %s", r.Status, r.RetryAt)
	}
}

func TestFromTempus_FreshAllOkRetriesAfterFiveDays(t *testing.T) {
	r := FromTempus(fixture(t, "query_past_all_ok.json"), past, past.Add(time.Hour))
	if r.Status != StatusProvisional {
		t.Errorf("status = %q", r.Status)
	}
	if !r.RetryAt.Equal(past.Add(120 * time.Hour)) {
		t.Errorf("retryAt = %s", r.RetryAt)
	}
	if len(r.Kinds) != 6 {
		t.Errorf("kinds = %v", r.Kinds)
	}
}

func TestFromTempus_FutureKeepsSunAndMoon(t *testing.T) {
	future := time.Date(2027, 6, 1, 12, 0, 0, 0, time.UTC)
	fetched := time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC)
	r := FromTempus(fixture(t, "query_future_weather_error.json"), future, fetched)
	if r.Status != StatusProvisional {
		t.Errorf("status = %q", r.Status)
	}
	if !r.RetryAt.Equal(future.Add(time.Hour)) {
		t.Errorf("retryAt = %s", r.RetryAt)
	}
	if !reflect.DeepEqual(r.Kinds, []string{"bioclim", "moon", "sun"}) {
		t.Errorf("kinds = %v", r.Kinds)
	}
	if r.Values["moon_phase"] != "abnehmende Sichel" || r.Values["moon_illumination_pct"] != 14.19 {
		t.Errorf("moon values = %v / %v", r.Values["moon_phase"], r.Values["moon_illumination_pct"])
	}
	if sr, _ := r.Values["sunrise"].(time.Time); !sr.Equal(time.Date(2027, 6, 1, 3, 18, 8, 0, time.UTC)) {
		t.Errorf("sunrise = %v", r.Values["sunrise"])
	}
}

func weatherOnly(props map[string]any) *services.TempusResponse {
	props["kind"] = "weather"
	return &services.TempusResponse{
		Features: []services.TempusFeature{{
			Properties: props,
			License:    json.RawMessage(`{"name":"CC-BY 4.0","url":"https://example.org","attribution":"x"}`),
		}},
		Providers: []services.TempusProvider{{ID: "open-meteo", Kind: "weather", Status: "ok"}},
	}
}

// 0 °C, 0 mm and 0 % are measurements, not gaps.
func TestFromTempus_ZeroValuesCount(t *testing.T) {
	r := FromTempus(weatherOnly(map[string]any{
		"temperature2m": 0.0, "precipitation": 0.0, "cloudCover": 0.0,
	}), past, pastFetch)
	for _, k := range []string{"weather_temperature_c", "weather_precipitation_mm", "weather_cloud_cover_pct"} {
		if v, ok := r.Values[k]; !ok || v != 0.0 {
			t.Errorf("%s = %v (present %v), want 0", k, v, ok)
		}
	}
	if !reflect.DeepEqual(r.Kinds, []string{"weather"}) {
		t.Errorf("kinds = %v", r.Kinds)
	}
	if _, ok := r.Values["weather_humidity_pct"]; ok {
		t.Error("a property Tempus did not send must stay absent")
	}

	// On the record the zeros are told apart from gaps by
	// conditions_fields: it lists exactly the delivered columns.
	rec := newSample(t)
	Apply(rec, r)
	want := []string{"weather_cloud_cover_pct", "weather_precipitation_mm", "weather_temperature_c"}
	if got := Fields(rec); !reflect.DeepEqual(got, want) {
		t.Errorf("fields = %v, want %v", got, want)
	}
}

// A null inside a delivered feature is a gap, not a zero.
func TestFromTempus_NullPropertyIsNotAField(t *testing.T) {
	r := FromTempus(weatherOnly(map[string]any{"temperature2m": nil, "precipitation": 2.5}), past, pastFetch)
	rec := newSample(t)
	Apply(rec, r)
	if got := Fields(rec); !reflect.DeepEqual(got, []string{"weather_precipitation_mm"}) {
		t.Errorf("fields = %v", got)
	}
}

func TestFromTempus_WindInOtherUnitIsNotStored(t *testing.T) {
	r := FromTempus(weatherOnly(map[string]any{
		"windSpeed10m": 4.2, "units": map[string]any{"windSpeed10m": "m/s"},
	}), past, pastFetch)
	if _, ok := r.Values["weather_wind_speed_kmh"]; ok {
		t.Error("wind in m/s must not land in the km/h column")
	}
	if len(r.Features) != 1 {
		t.Error("the feature itself must be kept")
	}
	rec := newSample(t)
	Apply(rec, r)
	if len(Fields(rec)) != 0 {
		t.Errorf("fields = %v: the wind column would read as a real 0 km/h", Fields(rec))
	}
}

func TestFromTempus_DropsFeatureWithoutLicenseOrKind(t *testing.T) {
	resp := weatherOnly(map[string]any{"temperature2m": 3.0})
	resp.Features[0].License = nil
	resp.Features = append(resp.Features, services.TempusFeature{
		Properties: map[string]any{"temperature2m": 5.0},
		License:    json.RawMessage(`{"name":"n"}`),
	})
	r := FromTempus(resp, past, pastFetch)
	if len(r.Features) != 0 || len(r.Kinds) != 0 || len(r.Values) != 0 {
		t.Errorf("features %d, kinds %v, values %v", len(r.Features), r.Kinds, r.Values)
	}
}

func TestFromTempus_ProviderErrorIsFinal(t *testing.T) {
	resp := fixture(t, "query_past_all_ok.json")
	kept := resp.Features[:0]
	for _, f := range resp.Features {
		if f.Kind() != "bioclim" {
			kept = append(kept, f)
		}
	}
	resp.Features = kept
	for i := range resp.Providers {
		if resp.Providers[i].ID == "bioclim" {
			resp.Providers[i].Status = "error"
		}
	}
	r := FromTempus(resp, past, pastFetch)
	if r.Status != StatusFinal || !r.RetryAt.IsZero() {
		t.Errorf("status %q, retryAt %s", r.Status, r.RetryAt)
	}
	for _, k := range r.Kinds {
		if k == "bioclim" {
			t.Error("bioclim listed without a feature")
		}
	}
}

func TestFromTempus_NilResponse(t *testing.T) {
	r := FromTempus(nil, past, pastFetch)
	if r.Status != StatusProvisional || len(r.Features) != 0 {
		t.Errorf("result = %+v", r)
	}
}

func newSample(t *testing.T) *core.Record {
	t.Helper()
	app := testutil.NewTestApp(t)
	coll, err := app.FindCollectionByNameOrId("samples")
	if err != nil {
		t.Fatal(err)
	}
	return core.NewRecord(coll)
}

func TestApplyAndClear(t *testing.T) {
	rec := newSample(t)
	rec.Set("notes", "bleibt")
	empty := Snapshot(rec)

	Apply(rec, FromTempus(fixture(t, "query_recent_weather_unavailable.json"), past, past.Add(3*time.Hour)))
	if rec.GetString("conditions_status") != StatusProvisional {
		t.Errorf("status = %q", rec.GetString("conditions_status"))
	}
	if !rec.GetDateTime("conditions_queried_for").Time().Equal(past) ||
		!rec.GetDateTime("conditions_retry_at").Time().Equal(past.Add(5*time.Hour)) ||
		!rec.GetDateTime("conditions_fetched_at").Time().Equal(past.Add(3*time.Hour)) {
		t.Errorf("dates = %v / %v / %v", rec.Get("conditions_queried_for"), rec.Get("conditions_retry_at"), rec.Get("conditions_fetched_at"))
	}
	if got := Fields(rec); len(got) != 12 || got[0] != "climate_altitudinal_belt" || got[len(got)-1] != "sunset" {
		t.Errorf("fields = %v", got)
	}
	if rec.GetFloat("precipitation_24h_mm") != 34 || rec.GetString("moon_phase") != "Vollmond" {
		t.Errorf("values not applied")
	}
	if rec.GetDateTime("sunrise").Time().IsZero() {
		t.Error("sunrise not applied")
	}
	if Snapshot(rec) == empty {
		t.Error("snapshot must change after Apply")
	}

	// A later answer without the aggregate kind removes its values.
	Apply(rec, FromTempus(fixture(t, "query_future_weather_error.json"),
		time.Date(2027, 6, 1, 12, 0, 0, 0, time.UTC), time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC)))
	if rec.GetFloat("precipitation_24h_mm") != 0 {
		t.Error("stale aggregate value kept")
	}

	Clear(rec)
	if rec.GetString("conditions_status") != StatusPending {
		t.Errorf("status after Clear = %q", rec.GetString("conditions_status"))
	}
	if len(Fields(rec)) != 0 || rec.GetString("moon_phase") != "" || !rec.GetDateTime("sunrise").Time().IsZero() ||
		!rec.GetDateTime("conditions_queried_for").Time().IsZero() {
		t.Error("Clear left values behind")
	}
	if rec.GetString("notes") != "bleibt" {
		t.Error("Clear touched a foreign field")
	}
	rec.Set("conditions_status", "")
	if Snapshot(rec) != empty {
		t.Errorf("snapshot after Clear differs from the empty record:\n%q\n%q", Snapshot(rec), empty)
	}
}

func TestSnapshot_IgnoresFetchedAt(t *testing.T) {
	rec := newSample(t)
	Apply(rec, FromTempus(fixture(t, "query_past_all_ok.json"), past, pastFetch))
	before := Snapshot(rec)
	rec.Set("conditions_fetched_at", pastFetch.Add(time.Hour))
	if Snapshot(rec) != before {
		t.Error("fetched_at must not count as a change")
	}
	rec.Set("conditions_retry_at", pastFetch.Add(time.Hour))
	if Snapshot(rec) != before {
		t.Error("retry_at must not count as a change")
	}
	rec.Set("weather_temperature_c", 17)
	if Snapshot(rec) == before {
		t.Error("a changed value must change the snapshot")
	}
}

func TestCheckDelivered(t *testing.T) {
	now := past.Add(400 * time.Hour)
	final := past.Add(FinalAfter)
	cases := []struct {
		name       string
		status     string
		fetched    time.Time
		retry      time.Time
		wantStatus string
		wantRetry  time.Time
		wantOK     bool
	}{
		{"no fetch date", StatusFinal, time.Time{}, time.Time{}, "", time.Time{}, false},
		{"fetched in the future", StatusFinal, now.Add(time.Hour), time.Time{}, "", time.Time{}, false},
		{"clock skew is tolerated", StatusFinal, now.Add(time.Minute), time.Time{}, StatusFinal, time.Time{}, true},
		{"final claimed for forecast data", StatusFinal, past.Add(time.Hour), time.Time{}, StatusProvisional, final, true},
		{"provisional without retry", StatusProvisional, past.Add(time.Hour), time.Time{}, StatusProvisional, final, true},
		{"retry far in the future", StatusProvisional, past.Add(time.Hour), past.Add(9999 * time.Hour), StatusProvisional, final, true},
		{"retry before the fetch", StatusProvisional, past.Add(2 * time.Hour), past.Add(time.Hour), StatusProvisional, final, true},
		{"sooner retry is kept", StatusProvisional, past.Add(time.Hour), past.Add(3 * time.Hour), StatusProvisional, past.Add(3 * time.Hour), true},
		{"final after five days", StatusFinal, past.Add(200 * time.Hour), past.Add(999 * time.Hour), StatusFinal, time.Time{}, true},
		{"old but a provider was unavailable", StatusProvisional, past.Add(200 * time.Hour), past.Add(202 * time.Hour), StatusProvisional, past.Add(202 * time.Hour), true},
		{"old, unavailable, no retry", StatusProvisional, past.Add(200 * time.Hour), time.Time{}, StatusProvisional, past.Add(201 * time.Hour), true},
		{"old, unavailable, retry too far", StatusProvisional, past.Add(200 * time.Hour), past.Add(300 * time.Hour), StatusProvisional, past.Add(201 * time.Hour), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			status, retry, ok := CheckDelivered(c.status, past, c.fetched, c.retry, now)
			if status != c.wantStatus || !retry.Equal(c.wantRetry) || ok != c.wantOK {
				t.Errorf("got (%q, %s, %v), want (%q, %s, %v)", status, retry, ok, c.wantStatus, c.wantRetry, c.wantOK)
			}
		})
	}
	// An instant that is still ahead: retry an hour after it.
	future := now.Add(72 * time.Hour)
	if status, retry, ok := CheckDelivered(StatusFinal, future, now, time.Time{}, now); status != StatusProvisional || !retry.Equal(future.Add(time.Hour)) || !ok {
		t.Errorf("future instant: (%q, %s, %v)", status, retry, ok)
	}
}
