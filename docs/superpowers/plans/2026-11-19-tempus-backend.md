# Tempus im Backend (PR 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabularius reichert jede Probe mit Koordinate über den Dienst Tempus mit Wetter, Klima, Sonne und Mond an, übernimmt passende Werte der App, zieht vorläufige Werte stündlich nach und hält die vollständigen Features als GeoJSON vor.

**Architecture:** Neues Paket `internal/conditions` mit purer Kernlogik (Abfragezeitpunkt, Abbildung der Tempus-Antwort auf Felder und Status). Neuer Wrapper `internal/services/tempus.go` nach dem Vorbild von `ortus.go`. Die Anreicherung läuft wie bei Ortus asynchron nach Request-Hooks in `internal/enrichment`, ein Cron-Job zieht nach. `sample_features` wird quellenbezogen ersetzt, damit Ortus und Tempus sich nicht gegenseitig löschen.

**Tech Stack:** Go, PocketBase als Library (`core.App`, Request-Hooks, `app.Cron()`), `log/slog`, `net/http/httptest` für Fakes.

**Nachtrag nach dem Review:** `conditions_kinds` wurde durch `conditions_fields` ersetzt (feldgenaue Liste der gelieferten Werte); die Aufgaben unten nennen noch den alten Namen.

**Spec:** `docs/superpowers/specs/2026-11-19-tempus-wetter-klima-design.md` (Abschnitte Datenhaltung, Ablauf/Backend, Wer gewinnt). App (PR 8), Backfill (PR 9) und Astro-Ablösung (PR 10) bekommen eigene Pläne.

## Global Constraints

- Branch `feat/tempus-backend` von `origin/main`. Commits: Conventional Commits, Scope `tabularius` (Doku: `docs`), Footer `Claude-Session: https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`; PR-Text endet mit `https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`.
- Keine Logik in `main.go`, dort nur Verdrahtung.
- Externe Aufrufe nur über den Wrapper, nie direkt aus einem Hook; Anreicherung in Goroutine mit Recover; sie darf Anlegen und Speichern einer Probe nie blockieren oder scheitern lassen.
- Logging nur `log/slog` mit den Keys aus `.claude/rules/LOGGING.md` (`sample_id`, `service` = `tempus`, `cache`, `duration_ms`, `err`). Keine Koordinaten, keine URLs mit Koordinaten, keine Request-Bodies.
- Echte Dienst-Adressen stehen nur als Default in den Compose-Dateien (wie `ORTUS_BASE_URL`), nie in Doku, Tests, Kommentaren, Commit- oder PR-Texten. Tests nutzen `httptest`, Doku nutzt `https://tempus.example`.
- `internal/conditions` ist Kernlogik: Tests zuerst, Coverage > 80 %.
- Feldnamen, Statuswerte und Zuordnung exakt wie in der Spec-Tabelle „Felder an `samples`“ inklusive `conditions_kinds`.
- Schwelle „endgültig“: Abfragezeitpunkt mindestens 5 Tage (120 h) vor dem Abruf.
- Vor dem PR: `cd tabularius && go test ./...` grün, `go vet ./...` sauber, die im Repo üblichen Linter (siehe CI-Workflow) ohne neue Befunde.
- `docs/plan/` nicht anfassen. Nach dem Öffnen des PRs: Skill `copilot-pr-review`.

## Review Focus

1. Echte Nullwerte: 0 °C, 0 mm, 0 % Bewölkung müssen als vorhandene Werte gelten. → `conditions_kinds`-Tests in Task 4.
2. Tempus nicht erreichbar oder Timeout beim Anlegen: Probe bleibt gespeichert, Status `pending`, der Job holt nach. → Tests in Task 6 und 7.
3. Ganztägige Probe am Tag einer Zeitumstellung und in einer Zone weit von UTC: 14:00 bzw. 22:00 gehören zum lokalen Kalendertag der Probe. → Tests in Task 2.
4. App schickt Werte, die zu einer älteren Koordinate oder einem älteren Zeitpunkt gehören: Backend verwirft sie und reichert selbst an. → Tests in Task 6.
5. Ortus-Lauf nach Tempus-Lauf (und umgekehrt) sowie ein altes App-`PUT` auf die Features: die Zeilen der jeweils anderen Quelle bleiben stehen. → Tests in Task 5.

---

### Task 1: Migration und Doku

**Files:**
- Create: `tabularius/migrations/1700000029_phase_t_tempus_conditions.go`
- Test: `tabularius/migrations/1700000029_phase_t_tempus_conditions_test.go`
- Modify: `PHASES.md` (Abschnitt „Phase T – Wetter, Klima und Astronomie über Tempus“ mit vier offenen Punkten für PR 7 bis 10, Statuszeile oben)
- Add: `docs/superpowers/specs/2026-11-19-tempus-wetter-klima-design.md`, dieser Plan

**Interfaces:**
- Produces: Felder an `samples` (alle optional):
  - `conditions_status` Select: `pending`, `provisional`, `final` (leer erlaubt)
  - `conditions_queried_for`, `conditions_fetched_at`, `conditions_retry_at`, `sunrise`, `sunset`: Date
  - `conditions_kinds`: JSON (Array von Strings)
  - Number: `weather_temperature_c`, `weather_humidity_pct`, `weather_dew_point_c`, `weather_precipitation_mm`, `weather_wind_speed_kmh`, `weather_cloud_cover_pct`, `weather_code`, `precipitation_24h_mm`, `precipitation_72h_mm`, `precipitation_120h_mm`, `day_temperature_min_c`, `day_temperature_max_c`, `day_temperature_mean_c`, `moon_illumination_pct`
  - Text: `climate_koppen_code`, `climate_altitudinal_belt`, `moon_phase`
  - Index `idx_samples_conditions_due` auf `(conditions_status, conditions_retry_at)`

- [ ] **Step 1:** `git fetch origin && git switch -c feat/tempus-backend origin/main`
- [ ] **Step 2: Failing Test** `TestPhaseTAddsConditionFields`: nach den Migrationen hat `samples` jedes der oben genannten Felder mit dem genannten Typ; ein vorhandener Datensatz behält `conditions_status == ""`. `TestPhaseTDownRemovesFields`: Down entfernt Felder und Index.
- [ ] **Step 3:** `cd tabularius && go test ./migrations -run PhaseT` → FAIL (Felder fehlen)
- [ ] **Step 4:** Migration im Stil von `1700000026_phase_z_time_id_elevation.go` schreiben (Up und Down, Kopfkommentar). Bestehende Datensätze werden nicht verändert.
- [ ] **Step 5:** Test grün, `go test ./migrations` grün
- [ ] **Step 6:** Commits `docs: Design und Plan für Tempus-Anreicherung (Phase T)` und `feat(tabularius): Felder für Wetter, Klima und Astronomie am Sample`

### Task 2: Abfragezeitpunkt

**Files:**
- Create: `tabularius/internal/conditions/instant.go`
- Test: `tabularius/internal/conditions/instant_test.go`

**Interfaces:**
- Produces:
  - `func QueryInstant(begin time.Time, zone string, allDay, night bool) time.Time` — immer UTC, auf Sekunden gekürzt. Mit Uhrzeit: `begin`. Ganztägig: 14:00 am lokalen Kalendertag von `begin` in `zone`; mit `night` 22:00. Unbekannte oder leere Zone: UTC.
  - `func SameInstant(a, b time.Time) bool` — gleich auf die Sekunde.
  - `const FinalAfter = 120 * time.Hour`
  - `func IsFinalAge(instant, fetchedAt time.Time) bool` — `fetchedAt - instant >= FinalAfter`.

- [ ] **Step 1: Failing Tests** (Tabelle):

| Fall | begin (UTC) | zone | allDay | night | erwartet (UTC) |
|---|---|---|---|---|---|
| mit Uhrzeit | 2026-07-01T09:07:30Z | Europe/Berlin | false | false | 2026-07-01T09:07:30Z |
| ganztägig Sommer | 2026-06-30T22:00:00Z | Europe/Berlin | true | false | 2026-07-01T12:00:00Z |
| ganztägig Winter | 2026-01-14T23:00:00Z | Europe/Berlin | true | false | 2026-01-15T13:00:00Z |
| ganztägig Nacht | 2026-06-30T22:00:00Z | Europe/Berlin | true | true | 2026-07-01T20:00:00Z |
| Tag der Zeitumstellung | 2026-03-28T23:00:00Z | Europe/Berlin | true | false | 2026-03-29T12:00:00Z |
| weit von UTC | 2026-11-16T11:00:00Z | Pacific/Auckland | true | false | 2026-11-17T01:00:00Z |
| unbekannte Zone | 2026-07-01T00:00:00Z | Nicht/Da | true | false | 2026-07-01T14:00:00Z |
| night ohne allDay | 2026-07-01T09:07:30Z | Europe/Berlin | false | true | 2026-07-01T09:07:30Z |

Dazu `IsFinalAge`: genau 120 h → true, 119 h 59 m → false, Zeitpunkt in der Zukunft → false.

- [ ] **Step 2:** `go test ./internal/conditions` → FAIL (Paket fehlt)
- [ ] **Step 3:** Implementieren (`time.LoadLocation`, `time.Date(y, m, d, 14|22, 0, 0, 0, loc)`)
- [ ] **Step 4:** Tests grün
- [ ] **Step 5:** Commit `feat(tabularius): Abfragezeitpunkt für Tempus berechnen`

### Task 3: Tempus-Wrapper

**Files:**
- Create: `tabularius/internal/services/tempus.go`
- Modify: `tabularius/internal/services/geocache.go` (neue Methode, `Get` ruft sie mit `ttl()` auf)
- Test: `tabularius/internal/services/tempus_test.go`
- Create: `shared/testdata/tempus/query_past_all_ok.json`, `query_recent_weather_unavailable.json`, `query_future_weather_error.json`

**Interfaces:**
- Consumes: `doWithRetry` aus `http.go`, `Geocache`.
- Produces:
  - `func (c *Geocache) GetMaxAge(service, key string, maxAge time.Duration) ([]byte, error)`
  - `type TempusResponse struct { Query struct{ Datetime time.Time }; Features []TempusFeature; Providers []TempusProvider }`
  - `type TempusFeature struct { Geometry json.RawMessage; Properties map[string]any; License json.RawMessage }` — `Kind()` liest `properties.kind`.
  - `type TempusProvider struct { ID, Kind, Status string; Cached, Retryable bool; RetryAfter string; Error string }` — `RetryAfterDuration() (time.Duration, bool)` parst die Go-Dauer (`"2h0m0s"`).
  - `type Tempus struct { BaseURL string; HTTPClient *http.Client; Cache *Geocache; MaxRetries int; Logger *slog.Logger; Now func() time.Time }`
  - `func (t *Tempus) Query(ctx context.Context, lat, lon float64, at time.Time) (*TempusResponse, error)`

Regeln: `GET {BaseURL}/api/v1/query?lat=%.6f&lon=%.6f&datetime=<RFC 3339 UTC>`. Cache-Service `"tempus"`, Schlüssel aus `CoordinateKey(lat, lon, <at auf volle UTC-Stunde als RFC 3339>)`. Lesen: `maxAge` 7 Tage, wenn `at` mindestens `conditions.FinalAfter` zurückliegt, sonst 1 Stunde. Schreiben nur, wenn kein Provider `unavailable` meldet. Unbekannte JSON-Felder werden ignoriert. Fehlertexte enthalten weder URL noch Koordinate (wie `ortus.go`). Log-Zeile pro Aufruf mit `service`, `cache` (`hit`/`miss`), `duration_ms`, bei Fehler `err`.

Fixtures: echte Antworten des Dienstes für München (48.1351, 11.5820, Beispiel aus dem Tempus-README): ein Zeitpunkt, der älter als 5 Tage ist; ein Zeitpunkt in der Zukunft. Die Variante „weather unavailable“ entsteht aus der ersten durch Handänderung (`open-meteo`: `status: "unavailable"`, `retryable: true`, `retryAfter: "2h0m0s"`, Wetter- und Taupunkt-Feature entfernt). Abruf mit der Adresse aus `TEMPUS_BASE_URL` der lokalen Umgebung; die Adresse wird nirgends festgehalten.

- [ ] **Step 1: Failing Tests:** `TestTempusQuery_DecodesAllKinds` (Fixture 1: sechs Features, Arten `weather`, `dewpoint`, `sun`, `moon`, `aggregate`, `bioclim`; alle Provider `ok`; Query-String enthält `lat=48.135100&lon=11.582000&datetime=`), `TestTempusQuery_RetryAfterDuration` (Fixture 2 → 2 h), `TestTempusQuery_FutureKeepsSunAndMoon` (Fixture 3), `TestTempusQuery_CachesFinalAnswer` (zweiter Aufruf trifft den Server nicht), `TestTempusQuery_DoesNotCacheUnavailable`, `TestTempusQuery_RecentAnswerExpiresAfterOneHour` (über `Now`), `TestTempusQuery_ErrorHidesURL` (500 → Fehlertext ohne `lat=` und ohne Host), `TestGeocacheGetMaxAge`.
- [ ] **Step 2:** `go test ./internal/services -run 'Tempus|GetMaxAge'` → FAIL
- [ ] **Step 3:** Implementieren
- [ ] **Step 4:** `go test ./internal/services` grün
- [ ] **Step 5:** Commit `feat(tabularius): Tempus-Wrapper mit Retry und Cache`

### Task 4: Antwort auf Felder, Status und Features abbilden

**Files:**
- Create: `tabularius/internal/conditions/map.go`
- Test: `tabularius/internal/conditions/map_test.go`

**Interfaces:**
- Consumes: `services.TempusResponse`, `geoplace.Feature`, `IsFinalAge`.
- Produces:
  - `const (StatusPending = "pending"; StatusProvisional = "provisional"; StatusFinal = "final")`
  - `const FeatureSourcePrefix = "tempus:"`
  - `type Result struct { Status string; QueriedFor, FetchedAt time.Time; RetryAt time.Time; Kinds []string; Values map[string]any; Features []geoplace.Feature }`
  - `func FromTempus(resp *services.TempusResponse, queriedFor, fetchedAt time.Time) Result`
  - `var ValueFields []string` — alle Wertfelder aus Task 1 (ohne `conditions_*`).
  - `func Apply(rec *core.Record, r Result)` — setzt `conditions_*`, alle `ValueFields` (nicht gelieferte auf Null-/Leerwert) und nichts sonst.
  - `func Clear(rec *core.Record)` — Status `pending`, `conditions_kinds` leer, `ValueFields` und die drei Zeitfelder geleert.
  - `func Snapshot(rec *core.Record) string` — vergleichbare Darstellung von `conditions_*` und `ValueFields`, ohne `conditions_fetched_at`.

Zuordnung Property → Feld:

| Art | Property | Feld |
|---|---|---|
| weather | `temperature2m` | `weather_temperature_c` |
| weather | `relativeHumidity2m` | `weather_humidity_pct` |
| weather | `precipitation` | `weather_precipitation_mm` |
| weather | `windSpeed10m` | `weather_wind_speed_kmh` |
| weather | `cloudCover` | `weather_cloud_cover_pct` |
| weather | `weatherCode` | `weather_code` |
| dewpoint | `dewPoint2m` | `weather_dew_point_c` |
| aggregate | `precipitation.last24h` / `.last72h` / `.last120h` | `precipitation_24h_mm` / `_72h_mm` / `_120h_mm` |
| aggregate | `temperatureDay.min` / `.max` / `.mean` | `day_temperature_min_c` / `_max_c` / `_mean_c` |
| bioclim | `koppen.code` | `climate_koppen_code` |
| bioclim | `altitudinalBelt.belt.de` | `climate_altitudinal_belt` |
| sun | `sunrise`, `sunset` (RFC 3339 oder null) | `sunrise`, `sunset` |
| moon | `phase.de` | `moon_phase` |
| moon | `illuminationPct` | `moon_illumination_pct` |

Regeln:
- `Kinds`: Art jedes gelieferten Features, sortiert, ohne Dopplungen.
- `Features`: eine `geoplace.Feature` pro Tempus-Feature, `SourceID = "tempus:" + kind`, `SourceName = "Tempus"`, `Layer = kind`, `FeatureID = ""`, `Properties` und `License` unverändert.
- Ein Feature ohne `kind` oder ohne Lizenzblock wird verworfen.
- `Status`: `provisional`, wenn ein Provider `unavailable` meldet, `queriedFor` nach `fetchedAt` liegt oder `!IsFinalAge`; sonst `final`. Provider mit `error` ändern den Status nicht.
- `RetryAt`: bei `final` leer. Sonst: liegt `queriedFor` in der Zukunft → `queriedFor + 1 h`; meldet ein Provider `unavailable` → `fetchedAt` + größte gemeldete `retryAfter`-Dauer (ohne Angabe 1 h); sonst `queriedFor + FinalAfter`.
- Windeinheit: Steht in `units.windSpeed10m` etwas anderes als `km/h`, bleibt `weather_wind_speed_kmh` ungesetzt (das Feature bleibt erhalten).

- [ ] **Step 1: Failing Tests** mit den drei Fixtures aus Task 3:
  - `TestFromTempus_PastAllOk`: Status `final`, `RetryAt` leer, `Kinds` = sechs Arten, jeder Tabellenwert gleich dem Wert im Fixture, sechs Features mit `SourceID`-Präfix `tempus:` und nicht leerer Lizenz.
  - `TestFromTempus_RecentIsProvisionalWithRetryAfter`: `fetchedAt` = `queriedFor + 3 h` → Status `provisional`, `RetryAt == fetchedAt + 2 h`, `Kinds` ohne `weather` und `dewpoint`.
  - `TestFromTempus_FreshAllOkRetriesAfterFiveDays`: Fixture 1 mit `fetchedAt = queriedFor + 1 h` → `provisional`, `RetryAt == queriedFor + 120 h`.
  - `TestFromTempus_FutureKeepsSunAndMoon`: `provisional`, `RetryAt == queriedFor + 1 h`, `Kinds` enthält `sun` und `moon`, nicht `weather`.
  - `TestFromTempus_ZeroValuesCount`: Wetter-Feature mit `temperature2m: 0`, `precipitation: 0`, `cloudCover: 0` → `Values` enthält die drei Schlüssel mit 0 und `Kinds` enthält `weather`.
  - `TestFromTempus_DropsFeatureWithoutLicense`.
  - `TestFromTempus_ProviderErrorIsFinal`: Fixture 1 mit `bioclim`-Provider `error`, Feature entfernt → `final`, `Kinds` ohne `bioclim`.
  - `TestApplyAndClear`: `Apply` gefolgt von `Clear` hinterlässt Status `pending` und leere Werte; `Snapshot` ist vor `Apply` und nach `Clear` gleich bis auf den Status.
- [ ] **Step 2:** `go test ./internal/conditions` → FAIL
- [ ] **Step 3:** Implementieren
- [ ] **Step 4:** grün; `go test ./internal/conditions -cover` → > 80 %
- [ ] **Step 5:** Commit `feat(tabularius): Tempus-Antwort auf Sample-Felder abbilden`

### Task 5: Features quellenbezogen ersetzen

**Files:**
- Modify: `tabularius/internal/geoplace/store.go` (`ReplaceFeatures`)
- Modify: `tabularius/internal/enrichment/enrichment.go` (`featuresChanged`, Aufruf von `ReplaceFeatures`)
- Modify: `tabularius/internal/api/sample_features.go`
- Modify: weitere Aufrufer von `ReplaceFeatures` (per `grep` finden, u.a. `internal/backfill`)
- Test: `tabularius/internal/geoplace/store_test.go`, `tabularius/internal/enrichment/enrichment_test.go`, Test der Route neben den bestehenden API-Tests

**Interfaces:**
- Produces:
  - `type FeatureScope string`; `const (ScopeOrtus FeatureScope = "ortus"; ScopeTempus FeatureScope = "tempus")`
  - `func ScopeOf(sourceID string) FeatureScope` — `tempus`, wenn `sourceID` mit `tempus:` beginnt, sonst `ortus`.
  - `func ReplaceFeatures(app core.App, sampleID, ownerID string, scope FeatureScope, fs []Feature) error` — löscht nur Zeilen des Scopes; ein Feature in `fs` mit anderem Scope → Fehler, nichts wird geändert.
  - `func FeaturesChanged(app core.App, sampleID string, scope FeatureScope, fs []Feature) bool` in `geoplace` (aus `enrichment.featuresChanged` verschoben, auf den Scope beschränkt).
  - Route: `PUT /api/samples/{id}/features?scope=tempus` ersetzt den Tempus-Scope; ohne Parameter oder mit `scope=ortus` den Ortus-Scope (bisheriges Verhalten alter App-Versionen). Unbekannter Scope oder ein Feature mit anderem Scope im Body → 400.

- [ ] **Step 1: Failing Tests:**
  - `TestReplaceFeatures_OrtusKeepsTempusRows` und `TestReplaceFeatures_TempusKeepsOrtusRows`.
  - `TestReplaceFeatures_RejectsForeignScope` (nichts geändert).
  - `TestFeaturesChanged_IgnoresOtherScope`.
  - Enrichment: nach einem Ortus-Lauf über eine Probe mit zwei `tempus:`-Zeilen sind beide noch da; ein zweiter identischer Ortus-Lauf erhöht `version` nicht.
  - Route: altes `PUT` ohne Parameter lässt `tempus:`-Zeilen stehen; `?scope=tempus` ersetzt nur sie; `?scope=tempus` mit Ortus-Feature → 400; fremde Probe → 404 wie bisher.
- [ ] **Step 2:** betroffene Pakete testen → FAIL (Signatur)
- [ ] **Step 3:** Implementieren, alle Aufrufer anpassen (Ortus-Aufrufer übergeben `ScopeOrtus`)
- [ ] **Step 4:** `go test ./...` grün
- [ ] **Step 5:** Commit `refactor(tabularius): Sample-Features quellenbezogen ersetzen`

### Task 6: Anreicherung und Rücksetzen

**Files:**
- Create: `tabularius/internal/enrichment/conditions.go`
- Create: `tabularius/internal/hooks/sample_conditions.go`
- Test: `tabularius/internal/enrichment/conditions_test.go`, `tabularius/internal/hooks/sample_conditions_test.go`

**Interfaces:**
- Consumes: `conditions.QueryInstant`, `SameInstant`, `FromTempus`, `Apply`, `Clear`, `Snapshot`, `services.Tempus.Query`, `geoplace.ReplaceFeatures(…, ScopeTempus, …)`, `geoplace.FeaturesChanged`.
- Produces:
  - `type ConditionsEnricher struct { App core.App; Tempus *services.Tempus; Logger *slog.Logger; Timeout time.Duration; Now func() time.Time }`
  - `func (e *ConditionsEnricher) Register()` — Request-Hooks auf `samples` (Create und Update), starten nach `ev.Next()` eine Goroutine mit Recover, wenn der gespeicherte Status `pending` ist.
  - `func (e *ConditionsEnricher) EnrichSample(ctx context.Context, sampleID string)` — synchron, für Job und Tests.
  - `func hooks.RegisterSampleConditionsReset(app core.App)` — Request-Hooks auf `samples` (Create und Update), vor dem Speichern.
  - `func hooks.SampleQueryInstant(app core.App, rec *core.Record) time.Time` — liest `begin_date`, `timezone`, `is_all_day` und `night_fieldtrip` der verknüpften Exkursion (fehlt sie: `false`) und ruft `conditions.QueryInstant`.

Regeln des Reset-Hooks (vor dem Speichern, pure Entscheidung in einer eigenen Funktion):
- Ohne Koordinate (`latitude == 0 && longitude == 0`): `conditions.Clear`, Status leer.
- Mit Koordinate: `want = SampleQueryInstant(rec)`.
  - Der Request liefert passende Werte, wenn `conditions_status` `provisional` oder `final` ist und `SameInstant(conditions_queried_for, want)`. Bei Update zusätzlich: Koordinate und `want` unverändert **oder** `conditions_queried_for`/`conditions_fetched_at` unterscheiden sich vom Original (die App hat neu geliefert). Dann bleibt alles, wie gesendet.
  - Sonst: `conditions.Clear(rec)` (Status `pending`). Bei Update geschieht das nur, wenn sich Koordinate oder `want` gegenüber dem Original geändert haben oder der Status vorher leer/`pending` war; ein unveränderter `provisional`/`final`-Datensatz bleibt unberührt.
- Der Hook ändert `version` nicht (das macht der bestehende Versions-Guard).

Regeln von `EnrichSample`:
- Probe lesen; ohne Koordinate, ohne `Tempus` oder Status nicht `pending`/`provisional` → nichts.
- `want` berechnen, `Tempus.Query` (ohne Transaktion). Fehler → Warnung loggen, Probe bleibt unverändert.
- In einer Transaktion neu lesen; haben sich Koordinate oder `want` inzwischen geändert → überspringen. `Apply`; unverändert (`Snapshot` gleich und Features gleich) → nur `conditions_fetched_at`/`conditions_retry_at` nicht anfassen, kein Speichern. Sonst `version + 1`, `SaveNoValidate`, `ReplaceFeatures(…, ScopeTempus, …)`.
- War die Probe beim Zurücksetzen `pending` geworden, werden ihre alten `tempus:`-Features spätestens hier ersetzt; bleibt die Abfrage erfolglos, löscht `EnrichSample` sie trotzdem (leere Liste), damit keine Features zu einer alten Koordinate stehen bleiben.

- [ ] **Step 1: Failing Tests** (Fake-Tempus per `httptest` mit den Fixtures, `Now` injiziert):
  - Hook: `TestReset_CreateWithoutValuesIsPending`, `TestReset_CreateWithMatchingClientValuesKeepsThem`, `TestReset_CreateWithValuesForOtherInstantIsCleared`, `TestReset_UpdateCoordinateMovedClears`, `TestReset_UpdateBeginChangedClears`, `TestReset_UpdateNotesOnlyKeepsFinal`, `TestReset_UpdateWithFreshClientValuesKeepsThem`, `TestReset_NoCoordinateHasEmptyStatus`, `TestReset_LegacySampleWithEmptyStatusStaysEmptyOnNotesUpdate`.
  - Enricher: `TestEnrich_PendingBecomesFinalAndWritesFeatures` (Version +1, sechs `tempus:`-Zeilen), `TestEnrich_SecondRunDoesNotBumpVersion`, `TestEnrich_TempusDownLeavesPending` (Version unverändert, kein Fehler nach außen), `TestEnrich_SkipsWhenCoordinateMovedMeanwhile`, `TestEnrich_KeepsOrtusFeatures`, `TestEnrich_PanicIsRecovered`, `TestEnrich_NilTempusDoesNothing`, `TestEnrich_AllDayNightUses22Local` (Fake prüft den `datetime`-Parameter).
- [ ] **Step 2:** → FAIL
- [ ] **Step 3:** Implementieren
- [ ] **Step 4:** `go test ./...` grün
- [ ] **Step 5:** Commit `feat(tabularius): Samples über Tempus anreichern`

### Task 7: Nachzieh-Job und Nachtexkursion

**Files:**
- Modify: `tabularius/internal/enrichment/conditions.go`
- Modify: `tabularius/internal/hooks/sample_create.go` (Stelle, an der `night_fieldtrip` geschrieben wird: `writeFieldtrip` und ihre Aufrufer)
- Test: `tabularius/internal/enrichment/conditions_test.go`, `tabularius/internal/hooks/sample_create_test.go`

**Interfaces:**
- Produces:
  - `func (e *ConditionsEnricher) RefreshDue(ctx context.Context, limit int) int` — verarbeitet höchstens `limit` Proben und gibt die Zahl der Abfragen zurück. Auswahl, älteste zuerst: Status `provisional` mit `conditions_retry_at <= now`; Status `pending` mit Koordinate, deren `updated` älter als 1 Stunde ist. Leerer Status wird nie gewählt.
  - `func (e *ConditionsEnricher) RegisterCron(limit int)` — `app.Cron().MustAdd("tempus-conditions", "7 * * * *", …)`, Lauf mit Recover und Gesamt-Timeout.
  - In `hooks`: ändert sich `night_fieldtrip` einer Exkursion, werden deren ganztägige Proben mit Koordinate und Status `provisional`/`final` auf `pending` gesetzt (`conditions.Clear`, `version + 1`), sofern ihr neuer Abfragezeitpunkt vom gespeicherten abweicht.

- [ ] **Step 1: Failing Tests:** `TestRefreshDue_PicksProvisionalPastRetryAt`, `TestRefreshDue_SkipsProvisionalBeforeRetryAt`, `TestRefreshDue_PicksStalePending`, `TestRefreshDue_SkipsFreshPending`, `TestRefreshDue_NeverTouchesEmptyStatus`, `TestRefreshDue_RespectsLimit`, `TestRefreshDue_OverwritesClientValuesWithFinal` (Probe mit von der App gelieferten vorläufigen Werten wird nach 5 Tagen `final`), `TestNightFlagFlip_ResetsAllDaySamples`, `TestNightFlagFlip_LeavesTimedSamples`.
- [ ] **Step 2:** → FAIL
- [ ] **Step 3:** Implementieren
- [ ] **Step 4:** `go test ./...` grün
- [ ] **Step 5:** Commit `feat(tabularius): vorläufige Tempus-Werte stündlich nachziehen`

### Task 8: Verdrahtung, Konfiguration, PR

**Files:**
- Modify: `tabularius/main.go` (im bestehenden `OnServe`-Block und bei den Hook-Registrierungen)
- Modify: `docker-compose.yml`, `docker-compose.prod.yml`, `docker-compose.staging.yml`, `docker-compose.test.yml`
- Modify: `docs/ENVIRONMENTS.md`, `CLAUDE.md` (Abschnitt „Externe Services“: ein Absatz zu Tempus, Adresse nur als Variable)

- [ ] **Step 1:** `main.go`: `hooks.RegisterSampleConditionsReset(app)` neben `RegisterSampleLocationReset` (vor dem Versions-Guard dieselbe Reihenfolge wie dort). Im `OnServe`-Block: `TEMPUS_BASE_URL` lesen; gesetzt → `services.Tempus{BaseURL, HTTPClient: httpClient, Cache: cache, MaxRetries: 3, Logger: slog.Default()}`, `ConditionsEnricher{…, Timeout: 15 * time.Second}`, `Register()`, `RegisterCron(200)`; leer → `slog.Warn("tempus: TEMPUS_BASE_URL leer, Anreicherung deaktiviert")`.
- [ ] **Step 2:** Compose-Dateien: Zeile `TEMPUS_BASE_URL: ${TEMPUS_BASE_URL:-<Default>}` direkt unter `ORTUS_BASE_URL`, Default nach demselben Muster wie dort. In `docker-compose.test.yml` ist der Default leer (die Test-Instanz fragt Tempus nicht ab, damit die iOS-Tests nicht vom Netz abhängen).
- [ ] **Step 3:** Doku ergänzen (Variable, Verhalten ohne Variable, stündlicher Job, Platzhalter-Adresse).
- [ ] **Step 4:** `cd tabularius && go build ./... && go vet ./... && go test ./...` → alles grün. `docker compose up --build -d`, eine Probe mit Koordinate über die API anlegen und prüfen: `conditions_status` wird `provisional` oder `final`, `sample_features` enthält `tempus:`-Zeilen, die Ortus-Zeilen sind noch da; Log zeigt `service=tempus` ohne Koordinaten. Danach Container stoppen.
- [ ] **Step 5:** Commit `feat(tabularius): Tempus-Anreicherung verdrahten und konfigurieren`
- [ ] **Step 6:** Push, `gh pr create --base main`, Titel `feat(tabularius): Wetter, Klima und Astronomie über Tempus anreichern`. PR-Text: was und warum, Datenmodell, Statusregeln, was geprüft wurde, was offen ist (App folgt in PR 8, Backfill in PR 9, bestehende Proben bleiben bis dahin leer, Hinweis an die iOS-App: `conditions_kinds` beachten). Danach `copilot-pr-review`.
