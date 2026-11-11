# Sample: Zeitzone, Zeitfenster, Sample-ID und Höhe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Samples speichern Zeiten in UTC mit eigener IANA-Zeitzone (Ortus `timezones-2026a`), Sample-ID und Rollover gehören dem User, es gibt nur noch eine Höhe.

**Architecture:** Backend-Migration `1700000026` bündelt alle Schemaänderungen (samples, fieldtrips, users); der Create-/Update-Hook vergibt keine IDs mehr und hängt nur noch den Konfliktsuffix an. Reine Logik der App (Viertelstunden-Rundung, Sammeltag, ID-Vorlage, Zeitzonen-Label) lebt im Swift-Package `FieldworksGeo`, weil dort `swift test` auf macOS Tahoe läuft; die App verdrahtet sie.

**Tech Stack:** Go 1.x + PocketBase v0.22 (Library), SwiftUI, GRDB, Swift Package `ios/Packages/FieldworksGeo`.

**Spec:** `docs/superpowers/specs/2026-11-09-sample-zeit-und-id-design.md`

## Global Constraints

- Phase heißt in `PHASES.md` **„Phase Z – Zeitzone, Sample-ID, Höhe“**; sie folgt auf O2, O3 kommt danach.
- Branch `feat/sample-zeit-id` auf Basis `feat/ortus-sample-ort`, eigene Worktree; nicht pushen.
- Conventional Commits; jede Commit-Message endet mit `Claude-Session: https://claude.ai/code/session_015iSEsSrMrE4BRew7xJkVcS`.
- Feldname `timezone` (nicht `time_zone`); Wert IANA-Kennung.
- `timezone_source` ∈ `device` | `location_service` | `manual`.
- `elevation_source` ∈ `location_service` | `backend_service` | `manual`; wird in der UI nicht angezeigt.
- Ortus-Quelle `timezones-2026a`, Wert `features[0].properties.tzid`; diese Quelle kommt nie in `sample_features`.
- Sample-ID: nach dem Speichern verändern App und Backend sie nie — einzige Ausnahme Konfliktsuffix `" (2)"`, `" (3)"` … (Leerzeichen vor der Klammer).
- Eindeutigkeit pro `(owner, sample_id)`, leere IDs ausgenommen.
- Default-Format `<YY><MM><DD>/<seq>`, Präfix leer, Offset 0, Rollover 0.
- Fallback-Zeitzone für Altdaten ohne `timezone`: `Europe/Berlin`.
- UI-Texte deutsch und exakt: „Diese Sample-ID ist bereits vergeben.“ · „ID doppelt vergeben – bitte prüfen“ · Einstellung „Tagesrollover“ · Vorlage „–“ heißt in der UI „– (leer lassen)“.
- Logging nach `.claude/rules/LOGGING.md` (keine Koordinaten, keine IDs von Usern im Klartext außer `user_id`); iOS nur über `Log.*`.
- iOS-UI nach `.claude/rules/DESIGN-SYSTEM.md` und `ACCESSIBILITY-IOS.md` (Tokens, Dynamic Type, VoiceOver-Labels, 44 pt).
- „Placemark“ ist nie user-sichtbar.
- App-Unit-Tests lassen sich auf Tahoe nicht per CLI ausführen: iOS-Tasks typechecken mit
  `cd ios && xcodegen generate && xcodebuild build-for-testing -project Fieldworksdiary.xcodeproj -scheme Fieldworksdiary -destination 'generic/platform=iOS Simulator' -IDEBuildingContinueBuildingAfterErrors=YES CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error:' | grep -v 'objc_abi_version\|Linker command failed'` → Ausgabe leer. App-Tests werden geschrieben, aber von Jo ausgeführt. Logik, die testbar sein muss, gehört ins Package (`cd ios/Packages/FieldworksGeo && swift test`).
- Backend: `cd backend && go test ./...` grün nach jedem Backend-Task.

## Rulings (vorab, gegen Spec)

- **Kein DB-UNIQUE-Index.** Die Spec verlangt Eindeutigkeit per Index, warnt aber vor dem PocketBase-Formvalidator (v0.22 lehnt kollidierende Records vor dem Hook ab, dann kann kein Suffix mehr gesetzt werden). Eindeutigkeit garantiert der Hook innerhalb der Transaktion (wie Phase 3b); der bestehende nicht-unique Index `(owner, sample_id)` bleibt. Kosten falls falsch: ein Index nachziehen.
- **`samples.collecting_day` wird neu angelegt** (text `YYYY-MM-DD`). Die Spec setzt voraus, dass die App den Sammeltag mitschickt; das Feld fehlt im Backend bisher (nur `fieldtrips.collecting_day`). Backfill aus der Exkursion.
- **`fieldtrips.timezone` wird neu angelegt** (Spec-Entscheidung 6: Exkursion rechnet mit der Zeitzone ihres ersten Samples; dafür muss sie gespeichert werden).
- **Konfliktmarker = `original_code`.** Hängt das Backend einen Suffix an, schreibt es die gesendete ID nach `original_code`. Die App zeigt den Hinweis, solange `original_code` nicht leer ist und ≠ `sample_id`; ändert der User die ID, leert die App `original_code` und schickt `""` mit.
- **Transiente DEM-Werte behalten ihren Namen.** `SampleGeo.ElevationDEM`/`elevationDEM` bleiben als Zwischenwerte im Mapping (Go und Swift); nur die Spalten verschwinden.
- **O3-Migrationsnummer:** O3 Task 20 war als `1700000026` geplant und wird `1700000027`.

## Review Focus

1. Sample um 23:50 Ortszeit mit Rollover 0 und Gerät in `Atlantic/Canary` → Sammeltag ist der kalendarische Tag in Canary, nicht in Berlin oder UTC. (Test in Task 4 und Task 2.)
2. Höhe 0 m mit Quelle `location_service` (Küste) → Ortus überschreibt sie nicht. (Test in Task 3 und Task 8.)
3. Leere Sample-ID zweimal beim selben User → kein Suffix, kein Fehler. (Test in Task 2 und Task 4.)
4. Zeitzone mit 30-min-Offset (`Asia/Kolkata`) → Beginn 12:03 lokal wird 12:00 lokal, nicht auf UTC-Viertel gerundet. (Test in Task 4.)
5. Update, das eine ID auf eine schon vergebene setzt (zweites Gerät) → Suffix statt 400/409. (Test in Task 2.)

---

### Task 0: Phasenstatus und Worktree (Controller)

- [ ] Worktree `.worktrees/sample-zeit-id` mit Branch `feat/sample-zeit-id` von `feat/ortus-sample-ort` anlegen (`.worktrees/` muss ignoriert sein, sonst in `.gitignore` ergänzen).
- [ ] `PHASES.md`: neuen Abschnitt „Phase Z – Zeitzone, Sample-ID, Höhe“ hinter Phase O mit Status „in progress“, Links auf Spec und Plan, Task-Liste 1–11; in Phase O vermerken, dass O3 nach Phase Z läuft und Task 20 die Migration `1700000027` bekommt.
- [ ] Commit `docs(phases): Phase Z eingetragen`.

### Task 1: Backend-Migration `1700000026`

**Files:** Create `backend/migrations/1700000026_phase_z_time_id_elevation.go`, `…_test.go`.

**Interfaces — Produces (Schema):**
- `samples`: `time_zone` → `timezone` (Daten erhalten); neu `timezone_source` (select `device`,`location_service`,`manual`, Backfill `device`); neu `collecting_day` (text, Backfill aus `fieldtrips.collecting_day` über `fieldtrip`); entfernt `elevation_dem`, `elevation_dem_accuracy`.
- `fieldtrips`: neu `timezone` (text, Backfill `Europe/Berlin`).
- `users`: neu `sample_id_format` (text), `sample_id_prefix` (text), `sample_id_offset` (number). `day_cutoff_hour` existiert und bleibt unangetastet.

- [ ] **Step 1: Failing tests** (Muster wie `1700000025_phase_o_sample_features_test.go`):
  - `TestPhaseZ_RenamesTimeZone` — Row mit `time_zone='Atlantic/Canary'` hat danach `timezone='Atlantic/Canary'`, Spalte `time_zone` existiert nicht.
  - `TestPhaseZ_MovesDEMIntoElevation` — Row `elevation=0, elevation_source='', elevation_dem=1147, elevation_dem_accuracy=4` → `elevation=1147, vertical_accuracy=4, elevation_source='backend_service'`; Row mit `elevation_source='location_service', elevation=0, elevation_dem=12` bleibt `elevation=0`, Quelle unverändert; Spalten `elevation_dem*` sind weg.
  - `TestPhaseZ_SuffixesExistingDuplicates` — zwei Rows `(owner A, '250611/3')` → zweite (später `created`) wird `'250611/3 (2)'` mit `original_code='250611/3'`; gleiche ID bei Owner B bleibt unverändert; zwei leere IDs bleiben leer.
  - `TestPhaseZ_BackfillsCollectingDayAndSource` — `collecting_day` = Datum der Exkursion, `timezone_source='device'`.
  - `TestPhaseZ_UserSettingsFields` — `users` hat die drei Felder, `day_cutoff_hour`-Wert eines Users bleibt.
- [ ] **Step 2:** `cd backend && go test ./migrations -run PhaseZ` → FAIL.
- [ ] **Step 3:** Migration implementieren; Reihenfolge: DEM-Übernahme vor dem Löschen, Duplikat-Suffix vor allem anderen am `sample_id`. Down-Migration: Spalten wiederherstellen (ohne Daten).
- [ ] **Step 4:** `go test ./...` → PASS.
- [ ] **Step 5:** Commit `feat(backend): Migration für Zeitzone, Sammeltag, Höhe und ID-Einstellungen`.

### Task 2: Backend-Hook – ID nie anfassen, Sammeltag aus Client/Zeitzone

**Files:** Modify `backend/internal/hooks/sample_create.go`, `sample_create_test.go`; ggf. neuer Update-Hook in `backend/internal/hooks/sample_update_id.go` (+Test) und Registrierung in `backend/main.go`; `backend/internal/codes/codes.go` (`CollectingDay` bleibt, `FormatCode`/`ParseSequence` entfallen, falls ungenutzt).

**Interfaces — Produces:**
- `func uniqueSampleID(dao *daos.Dao, ownerID, wanted, excludeID string) (string, error)` — `""` → `""`; frei → `wanted`; belegt → `wanted + " (n)"` mit kleinstem freien n ≥ 2. Prüft nur Samples desselben Owners.
- `func collectingDayFor(rec *models.Record, cutoffHour int) (day time.Time, loc *time.Location)` — `rec.collecting_day` gültig (`2006-01-02`) → dieser Tag; sonst `codes.CollectingDay(begin_date in timezone, cutoffHour)`; `timezone` leer/ungültig → `Europe/Berlin`.

- [ ] **Step 1: Failing tests:**
  - `TestCreate_KeepsClientID` — `sample_id='JB-17'` → gespeichert `'JB-17'`, `original_code` leer.
  - `TestCreate_EmptyIDStaysEmpty` — zwei Creates mit `sample_id=''` beim selben User → beide `''`.
  - `TestCreate_SuffixPerOwner` — Owner A hat `'250611/3'`; zweiter Create A `'250611/3'` → `'250611/3 (2)'`, `original_code='250611/3'`; dritter → `' (3)'`; Owner B `'250611/3'` → unverändert.
  - `TestCreate_UsesClientCollectingDay` — `collecting_day='2026-06-10'`, `begin_date=2026-06-11T02:00Z` → Exkursion des 10.06.
  - `TestCreate_ComputesDayInSampleTimezone` — kein `collecting_day`, `timezone='Atlantic/Canary'`, `begin_date=2026-01-15T23:50Z`, User-Rollover 0 → Sammeltag 2026-01-15 und `rec.collecting_day='2026-01-15'`; gleiche Zeit mit `timezone='Europe/Berlin'` → 2026-01-16.
  - `TestCreate_UserCutoffHour` — User `day_cutoff_hour=5`, `timezone='Europe/Berlin'`, `begin_date=2026-06-11T01:30Z` (03:30 lokal) → 2026-06-10.
  - `TestCreate_NewFieldtripTakesSampleTimezone` — neue Exkursion bekommt `timezone` des Samples; Exkursions-Zeitfenster in dieser Zone.
  - `TestUpdate_SuffixOnCollidingIDChange` — Update von Sample X auf eine bei A vergebene ID → `' (2)'` + `original_code`; Update ohne ID-Änderung lässt ID und `original_code` in Ruhe; Update auf eigene aktuelle ID → kein Suffix.
- [ ] **Step 2:** `go test ./internal/hooks -run 'Create_|Update_Suffix'` → FAIL.
- [ ] **Step 3:** `processSample` umbauen: keine Sequenzvergabe (`nextSequence`, `ensureSequenceAtLeast`, `codeConflicts` global entfernen; `sample_sequences` wird nicht mehr beschrieben), Cutoff aus `users.day_cutoff_hour` (fehlend → 0) statt `defaultCutoff`, `berlin` nur noch als Fallback; `fieldtripFromRecord`/`writeFieldtrip` nutzen `fieldtrips.timezone` (leer → Berlin). Update-Hook auf `samples` (`OnRecordBeforeUpdateRequest`) ruft `uniqueSampleID` nur, wenn sich `sample_id` geändert hat.
- [ ] **Step 4:** `go test ./...` → PASS.
- [ ] **Step 5:** Commit `feat(backend)!: Sample-ID wird nicht mehr vergeben oder umnummeriert` mit Footer `BREAKING CHANGE: Das Backend vergibt keine Sample-IDs mehr; Kollisionen pro User bekommen einen Suffix " (n)".`

### Task 3: Backend-Anreicherung – Zeitzone und eine Höhe

**Files:** Modify `backend/internal/geoplace/map.go`, `store.go`, `place.go` (SampleGeo), `backend/internal/services/ortus.go` nur falls Typen fehlen, `backend/internal/enrichment/enrichment.go`; Tests daneben; Fixture-Ergänzung `shared/testdata/ortus/query_de_ochsenfurt.json` um eine `timezones-2026a`-Quelle (Form wie Live-Antwort: `{"source_id":"timezones-2026a","features":[{"id":0,"layer":"timezones","properties":{"tzid":"Europe/Berlin"}}],"license":{…}}`), `expected_de_ochsenfurt.json` `feature_count` unverändert lassen.

**Interfaces — Produces:** `SampleGeo.Timezone string` (leer = unbekannt). Konstante `timezoneSource = "timezones-2026a"`.

- [ ] **Step 1: Failing tests:**
  - `TestFromOrtus_Timezone` — DE-Fixture → `res.Geo.Timezone == "Europe/Berlin"`; `res.Features` enthält keine Feature mit `SourceID == "timezones-2026a"`; `len(res.Features)` = Wert aus `expected_de_ochsenfurt.json`.
  - `TestApplyGeo_NoDEMColumns` — `ApplyGeo` setzt keine `elevation_dem*`-Felder (Record-Collection ohne diese Spalten speichert fehlerfrei).
  - `TestEnrich_SetsTimezoneUnlessManual` — `timezone_source='device'` → `timezone='Europe/Berlin'`, Quelle `location_service`; `timezone_source='manual'`, `timezone='Asia/Tokyo'` → unverändert.
  - `TestEnrich_ZeroMetreGPSHeightKept` — `elevation=0, elevation_source='location_service'` + DEM 236 → bleibt 0.
  - `TestEnrich_DEMWhenNoHeight` — `elevation_source=''` → `elevation=236, vertical_accuracy=4, elevation_source='backend_service'`.
  - Timezone-Änderung ändert weder `collecting_day` noch `fieldtrip` noch `sample_id`.
- [ ] **Step 2:** FAIL. **Step 3:** Implementieren (`applyDEMHeight` bleibt in der Logik, `ApplyGeo` ohne DEM-Spalten, Timezone in derselben Transaktion setzen). **Step 4:** `go test ./...` PASS.
- [ ] **Step 5:** Commit `feat(backend): Zeitzone aus Ortus, nur noch eine Höhe am Sample`.

### Task 4: FieldworksGeo – reine Zeit- und ID-Logik

**Files:** Create `ios/Packages/FieldworksGeo/Sources/FieldworksGeo/SampleTime.swift`, `SampleIDTemplate.swift`; Tests `…/Tests/FieldworksGeoTests/SampleTimeTests.swift`, `SampleIDTemplateTests.swift`. Modify `OrtusMapper.swift` (+ `OrtusMapperTests.swift`).

**Interfaces — Produces (alle `public`):**
- `enum SampleTime`
  - `static func roundedDown(_ date: Date, toMinutes: Int = 15, in tz: TimeZone) -> Date`
  - `static func defaultWindow(createdAt: Date, in tz: TimeZone) -> (begin: Date, end: Date)` — end = begin + 15 min.
  - `static func collectingDay(_ date: Date, cutoffHour: Int, in tz: TimeZone) -> String` — `"yyyy-MM-dd"`.
  - `static func timezoneLabel(_ tz: TimeZone, at date: Date) -> String` — `"Atlantic/Canary (WET)"`; Abkürzung über `tz.abbreviation(for:)`, Fallback nur Kennung.
- `struct SampleIDTemplate: Equatable, Sendable { let raw: String }`
  - `static let default = SampleIDTemplate(raw: "<YY><MM><DD>/<seq>")`, `static let empty = SampleIDTemplate(raw: "-")`
  - `static let presets: [SampleIDTemplate]` = default, `<YYYY><MM><DD>/<seq>`, `<YY><MM><DD>-<seq>`, `<seq>/<YY><MM><DD>`, `<PREFIX><n>`, `empty`.
  - `enum Counter { case none, daily, running }`, `var counter: Counter`, `var isValid: Bool` (nicht beide Zähler).
  - `func render(day: String /*yyyy-MM-dd*/, prefix: String, number: Int) -> String` — `empty` → `""`.
  - `static func nextSuggestion(template:prefix:day:existingIDs:lastRunning:offset:) -> (id: String, running: Int?)` — daily: kleinste Zahl > höchste bisher im selben Tag mit demselben Template gerenderte, deren Rendering nicht in `existingIDs` liegt; running: `max(lastRunning, offset) + 1`, bei Belegung weiterzählen; `running` im Ergebnis ist die verbrauchte Nummer (nur bei `.running`).
- `SampleGeo.timezone: String?`; `OrtusMapper` lässt Quelle `timezones-2026a` aus den Features weg.

- [ ] **Step 1: Failing tests** (Werte verbindlich):
  - `roundedDown(12:03:43 Europe/Berlin)` → 12:00:00; `12:29:59` → 12:15:00; `Asia/Kolkata` 12:03 lokal → 12:00 lokal.
  - `defaultWindow` → end − begin = 900 s.
  - `collectingDay(2026-01-15T23:50Z, cutoff 0, Atlantic/Canary)` → `"2026-01-15"`; gleiche Zeit in `Europe/Berlin` → `"2026-01-16"`; `2026-06-11T01:30Z`, cutoff 5, Berlin → `"2026-06-10"`.
  - `timezoneLabel(Atlantic/Canary, 2026-01-15)` → `"Atlantic/Canary (WET)"`; am 2026-07-15 → `"Atlantic/Canary (WEST)"`.
  - Template: `"<YY><MM><DD>/<seq><n>"` → `isValid == false`; `empty.render` → `""`; `<PREFIX><n>` mit Präfix `"JB-"`, Offset 1000, lastRunning 0 → `"JB-1001"`, running 1001; existingIDs enthält `"JB-1001"` → `"JB-1002"`; daily mit existingIDs `["260115/1","260115/2"]` → `"260115/3"`.
  - Ortus: Fixture mit `timezones-2026a` → `geo.timezone == "Europe/Berlin"`, keine Feature dieser Quelle.
- [ ] **Step 2:** `cd ios/Packages/FieldworksGeo && swift test` → FAIL. **Step 3:** implementieren. **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(ios): Zeit- und ID-Logik im Package FieldworksGeo`.

### Task 5: iOS-Persistenz und Sync-Schema

**Files:** Modify `ios/Fieldworksdiary/Core/Persistence/Database.swift` (Migration `v14_timezone_elevation`), `LocalSample.swift`, `LocalSampleStore.swift` (Mapping), `ios/Fieldworksdiary/Core/Models/Sample.swift`, `ios/Fieldworksdiary/Core/Sync/SyncRunner.swift` (Payload), betroffene App-Tests.

**Interfaces — Produces:** `LocalSample.timezone: String`, `LocalSample.timezoneSource: TimezoneSource?` (`enum TimezoneSource: String { case device, locationService = "location_service", manual }`), `LocalSample.elevationDEM`/`elevationDEMAccuracy` entfallen. `Sample` dekodiert `timezone` (Fallback-Key `time_zone`), `timezone_source`, `collecting_day`.

- [ ] **Step 1:** App-Tests anpassen/ergänzen (laufen bei Jo): Migrationstest v14 (Rename erhält Wert, DEM-Übernahme wie Task 1, Spalten weg), Decoder-Test für beide Keys, Payload enthält `timezone`, `timezone_source`, `collecting_day`, kein `elevation_dem`.
- [ ] **Step 2:** Implementieren; `mergeServerLocation`/`clearDerivedLocation` ohne DEM-Felder.
- [ ] **Step 3:** Typecheck (Global Constraints) → leer.
- [ ] **Step 4:** Commit `feat(ios): Zeitzone und eine Höhe in Persistenz und Sync`.

### Task 6: iOS-Einstellungen – Format, Präfix, Offset, Rollover

**Files:** Modify `ios/Fieldworksdiary/Core/Config/AppConfig.swift`, `ios/Fieldworksdiary/Core/Geo/Codes/SampleCodeTemplate.swift` (wird dünner Adapter auf `FieldworksGeo.SampleIDTemplate` oder entfällt), `ios/Fieldworksdiary/Features/Settings/SettingsView.swift`, `ios/Fieldworksdiary/Core/Auth/AuthClient.swift` bzw. Session-Code (User-Record lesen/patchen), `Localizable.xcstrings`.

**Interfaces — Produces:** `AppConfig.sampleIDFormat: String`, `.sampleIDPrefix: String`, `.sampleIDOffset: Int`, `.dayCutoffHour: Int` (UserDefaults-gecacht, Defaults aus Global Constraints); `AppConfig.lastRunningNumber: Int` (nur lokal). `func syncUserSettings()` — nach Login/Auth-Refresh Werte aus dem User-Record übernehmen (leer → Default); bei Änderung in den Einstellungen `PATCH /api/collections/users/records/{id}` mit `sample_id_format`, `sample_id_prefix`, `sample_id_offset`, `day_cutoff_hour`, Fehler nur loggen.

- [ ] **Step 1:** App-Tests (bei Jo): Default-Werte, ungültiges Format wird nicht übernommen, Mapping User-Record → AppConfig.
- [ ] **Step 2:** SettingsView: Abschnitt Sample-ID mit Preset-Auswahl („– (leer lassen)“ als Label für `-`), Präfix-Textfeld, Offset-Stepper/Feld (nur bei `<n>`-Format sichtbar), Vorschau des nächsten Vorschlags; Abschnitt „Tagesrollover“ (Picker 0–23 Uhr, Anzeige „0:00“ … „23:00“, Hinweis „gilt in der Ortszeit des Samples“).
- [ ] **Step 3:** Typecheck → leer. **Step 4:** Commit `feat(ios): Einstellungen für Sample-ID-Format und Tagesrollover`.

### Task 7: iOS-Anlegen – Zeitfenster, Sammeltag, Vorschlag, Eindeutigkeit

**Files:** Modify `LocalSampleStore.swift` (`createLocal`, `peekNextCode`, `findByCode`, Sequenz-Helfer), `ios/Fieldworksdiary/Features/Home/HomeViewModel.swift`, `ios/Fieldworksdiary/Features/SampleEditor/SampleEditorViewModel.swift`, App-Tests.

**Interfaces — Consumes:** `SampleTime`, `SampleIDTemplate.nextSuggestion` (Task 4), `AppConfig`-Werte (Task 6).

- [ ] **Step 1: App-Tests (bei Jo):** `createLocal` setzt `timezone = TimeZone.current.identifier` (injizierbar), `timezoneSource = .device`, `beginDate`/`endDate` = `defaultWindow`, `collectingDay` aus `SampleTime.collectingDay` mit `AppConfig.dayCutoffHour`; leere ID wird gespeichert; `findByCode("")` findet nie etwas; Vorschlag mit `<PREFIX><n>` erhöht `lastRunningNumber` nur, wenn der Vorschlag unverändert übernommen wurde.
- [ ] **Step 2:** Implementieren. `cutoffHour: Int = 5` und `Europe/Berlin` als Store-Defaults entfernen (Zeitzone injizierbar, Default `TimeZone.current`). Editor: Format-Regex `^\d{6}/\d+$` entfällt (jedes Format erlaubt); Duplikat-Meldung exakt „Diese Sample-ID ist bereits vergeben.“; leere ID ist gültig.
- [ ] **Step 3:** Typecheck → leer. **Step 4:** Commit `feat(ios): Anlegen mit Viertelstunden-Fenster, Ortszeit-Sammeltag und ID-Vorschlag`.

### Task 8: iOS-Ortsauflösung – Zeitzone und Höhe

**Files:** Modify `ios/Fieldworksdiary/Core/Geo/SampleLocationResolver.swift`, App-Tests dazu.

- [ ] **Step 1: App-Tests (bei Jo):** Ortus-Ergebnis mit `timezone="Atlantic/Canary"` → Sample `timezone` gesetzt, Quelle `.locationService`; bei `.manual` unverändert; `collectingDay`, `fieldtrip`, `sampleID` unverändert; Höhe 0 mit `.locationService` bleibt; ohne Quelle → DEM-Höhe + Fehler, `.backendService`.
- [ ] **Step 2:** Implementieren (`applyGeo` ohne DEM-Felder; „Höhe vorhanden“ = `elevationSource != nil`). Geänderte Zeitzone wird wie die Ortsfelder als Update gepusht.
- [ ] **Step 3:** Typecheck → leer. **Step 4:** Commit `feat(ios): Zeitzone aus Ortus übernehmen`.

### Task 9: iOS-UI – Ortszeit, Zeitzonen-Anzeige, Zeitfenster und Zeitzonenwahl

**Files:** Modify `ios/Fieldworksdiary/Features/Samples/SampleDetailView.swift`, `SamplesListView.swift`, `ios/Fieldworksdiary/Features/SampleEditor/SampleEditorView.swift`, `SampleEditorViewModel.swift`, `LocalSampleStore.swift` (`saveEdits` um Zeitfelder), Create `ios/Fieldworksdiary/Features/SampleEditor/TimeZonePickerView.swift`, `Localizable.xcstrings`.

- [ ] **Step 1:** Alle Datums-/Zeitformatter für Samples bekommen `timeZone = TimeZone(identifier: sample.timezone) ?? .current` (Liste, Detail, Editor, Home-/Kalender-Zeilen, falls sie Uhrzeiten zeigen).
- [ ] **Step 2:** Detail und Editor: direkt unter dem Datum `SampleTime.timezoneLabel(tz, at: beginDate)` in sekundärem Stil.
- [ ] **Step 3:** Editor (bestehendes Sample): Beginn und Ende als `DatePicker` (Datum + Uhrzeit, `environment(\.timeZone, sampleTZ)`), Ende ≥ Beginn erzwingen; Zeile „Zeitzone“ öffnet `TimeZonePickerView`: Liste der Regionen (Präfix vor dem ersten `/` aus `TimeZone.knownTimeZoneIdentifiers`, alphabetisch), dann Zonen der Region, aktuelle mit Häkchen und `.isSelected`-Trait. Auswahl setzt `timezone`, `timezoneSource = .manual`, UTC-Zeitpunkte bleiben gleich.
- [ ] **Step 4:** `saveEdits` persistiert `beginDate`, `endDate`, `timezone`, `timezoneSource` und pusht sie.
- [ ] **Step 5:** Typecheck → leer; Anti-Pattern-Greps aus beiden Regel-Dateien über geänderte Dateien → keine neuen Treffer.
- [ ] **Step 6:** Commit `feat(ios): Ortszeit-Anzeige, Zeitfenster und Zeitzonenwahl im Sample`.

### Task 10: iOS-UI – Höhe bearbeiten, Konflikthinweis

**Files:** Modify `SampleEditorView.swift`, `SampleEditorViewModel.swift`, `LocalSampleStore.swift` (`setManualElevation`), `SampleDetailView.swift`, `SamplesListView.swift`, `Localizable.xcstrings`.

**Interfaces — Produces:** `func setManualElevation(id: String, elevation: Double, verticalAccuracy: Double?, mutationsStore: PendingMutationsStore) throws` — setzt Quelle `.manual`, Fehler = übergebener Wert oder `nil`.

- [ ] **Step 1: App-Tests (bei Jo):** Höhe ändern → `.manual`, `verticalAccuracy` nil ohne Eingabe, sonst der eingegebene Wert; ID-Änderung leert `originalCode`.
- [ ] **Step 2:** Editor: Höhe editierbar (auch wenn leer), optionales Feld „Fehler (m)“; `elevationSourceText` und jede sichtbare Quellenangabe der Höhe entfernen; `vertical_accuracy` weiter als „± n m“.
- [ ] **Step 3:** Konflikthinweis: Liste und Detail zeigen bei `originalCode` nicht leer und ≠ `sampleID` den Hinweis „ID doppelt vergeben – bitte prüfen“ (Icon + Text, nicht nur Farbe). Bisherige `backendCode`-Anzeige auf diese Logik umstellen (SyncRunner übernimmt die Server-ID in `sampleID`; `backendCode` entfällt, falls danach ungenutzt).
- [ ] **Step 4:** Typecheck → leer, Anti-Pattern-Greps. **Step 5:** Commit `feat(ios): eine Höhe mit optionalem Fehler, Hinweis bei doppelter ID`.

### Task 11: Phase Z abschließen (Controller)

- [ ] `go test ./...` und `swift test` grün; Typecheck leer.
- [ ] Demo gegen lokales Backend + `https://ortus.fieldworksdiary.org` per curl: Create ohne `collecting_day` mit `timezone='Atlantic/Canary'`; doppelte ID → Suffix; Enrichment setzt `timezone` und lässt Features ohne `timezones-2026a`.
- [ ] `PHASES.md`: Phase Z „implementiert, wartet auf Test durch Jo“ (App-Tests + Simulator); Commit `docs(phases): Phase Z implementiert, Test durch Jo ausstehend`.
