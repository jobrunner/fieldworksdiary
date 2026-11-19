package conditions

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/core"

	"go.mett.io/tabularius/internal/geoplace"
	"go.mett.io/tabularius/internal/services"
)

// conditions_status values of a sample. Empty means "never processed"
// (rows from before Phase T, or a sample without coordinate).
const (
	StatusPending     = "pending"
	StatusProvisional = "provisional"
	StatusFinal       = "final"
)

// FeatureSourcePrefix starts the source_id of every Tempus row in
// sample_features ("tempus:weather", …).
const FeatureSourcePrefix = geoplace.TempusSourcePrefix

const featureSourceName = "Tempus"

// defaultRetry is the wait when a provider is unavailable without a
// retryAfter hint, and after an instant that still lies in the future.
const defaultRetry = time.Hour

type valueType int

const (
	typeNumber valueType = iota
	typeText
	typeDate
)

// valueSpec maps one property of a feature kind onto a sample field.
type valueSpec struct {
	field string
	kind  string
	path  []string
	typ   valueType
}

var valueSpecs = []valueSpec{
	{"weather_temperature_c", "weather", []string{"temperature2m"}, typeNumber},
	{"weather_humidity_pct", "weather", []string{"relativeHumidity2m"}, typeNumber},
	{"weather_dew_point_c", "dewpoint", []string{"dewPoint2m"}, typeNumber},
	{"weather_precipitation_mm", "weather", []string{"precipitation"}, typeNumber},
	{"weather_wind_speed_kmh", "weather", []string{"windSpeed10m"}, typeNumber},
	{"weather_cloud_cover_pct", "weather", []string{"cloudCover"}, typeNumber},
	{"weather_code", "weather", []string{"weatherCode"}, typeNumber},
	{"precipitation_24h_mm", "aggregate", []string{"precipitation", "last24h"}, typeNumber},
	{"precipitation_72h_mm", "aggregate", []string{"precipitation", "last72h"}, typeNumber},
	{"precipitation_120h_mm", "aggregate", []string{"precipitation", "last120h"}, typeNumber},
	{"day_temperature_min_c", "aggregate", []string{"temperatureDay", "min"}, typeNumber},
	{"day_temperature_max_c", "aggregate", []string{"temperatureDay", "max"}, typeNumber},
	{"day_temperature_mean_c", "aggregate", []string{"temperatureDay", "mean"}, typeNumber},
	{"climate_koppen_code", "bioclim", []string{"koppen", "code"}, typeText},
	{"climate_altitudinal_belt", "bioclim", []string{"altitudinalBelt", "belt", "de"}, typeText},
	{"sunrise", "sun", []string{"sunrise"}, typeDate},
	{"sunset", "sun", []string{"sunset"}, typeDate},
	{"moon_phase", "moon", []string{"phase", "de"}, typeText},
	{"moon_illumination_pct", "moon", []string{"illuminationPct"}, typeNumber},
}

// ValueFields are the sample fields that carry Tempus values (without
// the conditions_* bookkeeping fields). Number columns cannot be empty:
// a column counts only when it is listed in conditions_fields.
var ValueFields = func() []string {
	names := make([]string, 0, len(valueSpecs))
	for _, s := range valueSpecs {
		names = append(names, s.field)
	}
	return names
}()

// windField is stored only when Tempus reports it in windUnit.
const (
	windField    = "weather_wind_speed_kmh"
	windProperty = "windSpeed10m"
	windUnit     = "km/h"
)

// Result is a Tempus answer mapped onto a sample.
type Result struct {
	Status     string
	QueriedFor time.Time
	FetchedAt  time.Time
	// RetryAt is when to ask again; zero for a final result.
	RetryAt time.Time
	// Kinds are the feature kinds Tempus delivered, sorted (not stored:
	// on the record conditions_fields says which values exist).
	Kinds []string
	// Values holds only the fields Tempus delivered (numbers as
	// float64, texts as string, dates as time.Time).
	Values   map[string]any
	Features []geoplace.Feature
}

// FromTempus maps a Tempus answer for the instant queriedFor, fetched at
// fetchedAt. Every feature of an ok provider is taken over, so a partial
// answer still fills what it can (sun and moon work for any instant).
// Features without kind or license are dropped.
//
// The result is provisional while a provider is unavailable, the
// instant lies in the future, or it was younger than FinalAfter when
// fetched (forecast data, replaced by the archive later). A provider
// error is final: asking again returns the same.
func FromTempus(resp *services.TempusResponse, queriedFor, fetchedAt time.Time) Result {
	r := Result{
		QueriedFor: queriedFor.UTC(),
		FetchedAt:  fetchedAt.UTC(),
		Values:     map[string]any{},
	}
	if resp == nil {
		r.Status = StatusProvisional
		r.RetryAt = r.FetchedAt.Add(defaultRetry)
		return r
	}

	byKind := map[string]map[string]any{}
	for _, f := range resp.Features {
		kind := f.Kind()
		if kind == "" || !hasLicense(f.License) {
			continue
		}
		if _, seen := byKind[kind]; !seen {
			r.Kinds = append(r.Kinds, kind)
		}
		byKind[kind] = f.Properties
		r.Features = append(r.Features, geoplace.Feature{
			SourceID:   FeatureSourcePrefix + kind,
			SourceName: featureSourceName,
			Layer:      kind,
			Properties: f.Properties,
			License:    f.License,
		})
	}
	sort.Strings(r.Kinds)

	for _, spec := range valueSpecs {
		props, ok := byKind[spec.kind]
		if !ok {
			continue
		}
		if spec.field == windField && !windInKmh(props) {
			continue
		}
		if v, ok := lookup(props, spec.path, spec.typ); ok {
			r.Values[spec.field] = v
		}
	}

	r.Status, r.RetryAt = statusOf(resp.Providers, r.QueriedFor, r.FetchedAt)
	return r
}

func statusOf(providers []services.TempusProvider, queriedFor, fetchedAt time.Time) (string, time.Time) {
	var unavailable bool
	var longest time.Duration
	for _, p := range providers {
		if p.Status != services.TempusStatusUnavailable {
			continue
		}
		unavailable = true
		d, ok := p.RetryAfterDuration()
		if !ok {
			d = defaultRetry
		}
		if d > longest {
			longest = d
		}
	}
	switch {
	case queriedFor.After(fetchedAt):
		return StatusProvisional, queriedFor.Add(defaultRetry)
	case unavailable:
		return StatusProvisional, fetchedAt.Add(longest)
	case !IsFinalAge(queriedFor, fetchedAt):
		return StatusProvisional, queriedFor.Add(FinalAfter)
	default:
		return StatusFinal, time.Time{}
	}
}

// hasLicense reports whether the license block is a non-empty object.
func hasLicense(raw json.RawMessage) bool {
	var lic map[string]any
	return len(raw) > 0 && json.Unmarshal(raw, &lic) == nil && len(lic) > 0
}

func windInKmh(props map[string]any) bool {
	units, ok := props["units"].(map[string]any)
	if !ok {
		return true
	}
	unit, ok := units[windProperty].(string)
	return !ok || unit == windUnit
}

// lookup walks path through nested objects and converts the leaf.
func lookup(props map[string]any, path []string, typ valueType) (any, bool) {
	var cur any = props
	for _, key := range path {
		obj, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		cur, ok = obj[key]
		if !ok {
			return nil, false
		}
	}
	switch typ {
	case typeNumber:
		n, ok := cur.(float64)
		return n, ok
	case typeText:
		s, ok := cur.(string)
		return s, ok && s != ""
	default:
		s, ok := cur.(string)
		if !ok {
			return nil, false
		}
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			return nil, false
		}
		return t.UTC(), true
	}
}

// Apply writes the result onto the sample: the conditions_* fields
// (conditions_fields lists the delivered values) and every value field. A value Tempus did not deliver is reset, so nothing
// from an earlier answer survives. No other field is touched.
func Apply(rec *core.Record, r Result) {
	rec.Set("conditions_status", r.Status)
	setDate(rec, "conditions_queried_for", r.QueriedFor)
	setDate(rec, "conditions_fetched_at", r.FetchedAt)
	setDate(rec, "conditions_retry_at", r.RetryAt)
	fields := make([]string, 0, len(r.Values))
	for field := range r.Values {
		fields = append(fields, field)
	}
	sort.Strings(fields)
	rec.Set("conditions_fields", fields)
	for _, spec := range valueSpecs {
		v := r.Values[spec.field]
		switch spec.typ {
		case typeNumber:
			n, _ := v.(float64)
			rec.Set(spec.field, n)
		case typeText:
			s, _ := v.(string)
			rec.Set(spec.field, s)
		default:
			t, _ := v.(time.Time)
			setDate(rec, spec.field, t)
		}
	}
}

// Clear resets the sample to "pending": no values, no kinds, no dates.
func Clear(rec *core.Record) {
	Apply(rec, Result{Status: StatusPending})
}

func setDate(rec *core.Record, field string, t time.Time) {
	if t.IsZero() {
		rec.Set(field, "")
		return
	}
	rec.Set(field, t.UTC())
}

// Fields reads conditions_fields from the sample: the value fields
// Tempus actually delivered, sorted. A number column not listed here
// holds no value, whatever it reads (PocketBase has no empty number, and
// 0 °C is a real temperature).
func Fields(rec *core.Record) []string {
	var fields []string
	_ = rec.UnmarshalJSONField("conditions_fields", &fields)
	return fields
}

// HasValue reports whether the sample holds a delivered value in field.
func HasValue(rec *core.Record, field string) bool {
	for _, f := range Fields(rec) {
		if f == field {
			return true
		}
	}
	return false
}

// Snapshot renders the conditions of a sample as one comparable string.
// conditions_fetched_at and conditions_retry_at are left out: a re-query
// that only moves them is no change a client has to hear about.
func Snapshot(rec *core.Record) string {
	var b strings.Builder
	fmt.Fprintf(&b, "status=%s\x00", rec.GetString("conditions_status"))
	fmt.Fprintf(&b, "for=%s\x00", rec.GetDateTime("conditions_queried_for").String())
	fmt.Fprintf(&b, "fields=%s\x00", strings.Join(Fields(rec), ","))
	for _, spec := range valueSpecs {
		switch spec.typ {
		case typeNumber:
			fmt.Fprintf(&b, "%s=%v\x00", spec.field, rec.GetFloat(spec.field))
		case typeText:
			fmt.Fprintf(&b, "%s=%s\x00", spec.field, rec.GetString(spec.field))
		default:
			fmt.Fprintf(&b, "%s=%s\x00", spec.field, rec.GetDateTime(spec.field).String())
		}
	}
	return b.String()
}

// Bounds for what a client may say about values it fetched itself.
const (
	// clockSkew is how far a client's fetch date may lie ahead of ours.
	clockSkew = 5 * time.Minute
	// maxUnavailableRetry caps the retry a client reports for a
	// provider that was unavailable.
	maxUnavailableRetry = 24 * time.Hour
)

// CheckDelivered validates the bookkeeping a client sent along with
// values it fetched from Tempus itself, for the instant queriedFor. The
// values are the client's; status and retry date follow from the dates,
// so a wrong status cannot keep forecast data from being replaced or a
// sample out of the refresh job:
//
//   - no fetch date, or one in the future: not usable (ok = false)
//   - instant still in the future: provisional, retry an hour after it
//   - fetched before the instant was FinalAfter old: provisional, retry
//     when it is — or sooner if the client says so
//   - fetched later: final as claimed; a claimed "provisional" (a
//     provider was unavailable) keeps a retry within a day
func CheckDelivered(status string, queriedFor, fetchedAt, retryAt, now time.Time) (string, time.Time, bool) {
	if fetchedAt.IsZero() || fetchedAt.After(now.Add(clockSkew)) {
		return "", time.Time{}, false
	}
	within := func(lo, hi, def time.Time) time.Time {
		if retryAt.IsZero() || retryAt.Before(lo) || retryAt.After(hi) {
			return def
		}
		return retryAt
	}
	switch {
	case queriedFor.After(fetchedAt):
		return StatusProvisional, queriedFor.Add(defaultRetry), true
	case !IsFinalAge(queriedFor, fetchedAt):
		final := queriedFor.Add(FinalAfter)
		return StatusProvisional, within(fetchedAt, final, final), true
	case status == StatusFinal:
		return StatusFinal, time.Time{}, true
	default:
		return StatusProvisional, within(fetchedAt, fetchedAt.Add(maxUnavailableRetry), fetchedAt.Add(defaultRetry)), true
	}
}
