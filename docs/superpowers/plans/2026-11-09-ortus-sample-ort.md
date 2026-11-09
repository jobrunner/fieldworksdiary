# Ortsdaten am Sample über Ortus – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ortus ersetzt labelloc und coordstomtb. Samples bekommen flache Ortsdaten (Placemark), Features pro Sample, MTB aus `tk25-blattschnitt-de` plus berechnetem Quadranten, online sofort in der App und offline nachträglich über das Backend.

**Architecture:** Reine Logik (Label-Tabelle, Ortus→Spalten-Mapping, Dedup-Hash, TK25-Quadrant) existiert zweimal mit **gemeinsamen Testvektoren unter `shared/`**: in Go (`backend/internal/adminlabels`, `geoplace`, `mtb`) und in einem neuen lokalen Swift-Package `ios/Packages/FieldworksGeo`. Backend: Ortus-Wrapper in `internal/services`, Anreicherung in `internal/enrichment`, zwei neue Endpoints (Placemark auflösen, Features ersetzen). iOS: GRDB-Spiegel, Ortus-Client, Sync über die neuen Endpoints.

**Tech Stack:** Go 1.26 + PocketBase (Library), `gopkg.in/yaml.v3` (nur Generator), Swift 5.9+/SwiftUI, GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-09-ortus-sample-ort-design.md`

## Global Constraints

- Phasen strikt nacheinander: **O1 Backend → Stop + Demo → O2 iOS → Stop + Demo → O3 Backfill/Aufräumen.** Statuswechsel zuerst in `PHASES.md`.
- Englische Bezeichner, deutsche UI-Strings. Conventional Commits, Commit-Body endet mit `Claude-Session: https://claude.ai/code/session_015iSEsSrMrE4BRew7xJkVcS`.
- Alle Wire-Werte snake_case: `location_source` ∈ {`user`,`location_service`,`sample`,`locality`}; `elevation_source` ∈ {`location_service`,`backend_service`,`manual`}; `location_status` ∈ {`backend_service`,`inherited`,`manual`,`pending`}; `geocoding_source` ∈ {`backend_service`,`manual`}.
- Der Begriff „Placemark“ erscheint nie in UI-Strings.
- Logging nur `log/slog` (Backend) bzw. `Log.<category>` (iOS) nach `.claude/rules/LOGGING.md`; Koordinaten nie mit mehr als 2 Nachkommastellen loggen.
- Backend-Kernlogik (`adminlabels`, `geoplace`, `mtb`) > 80 % Coverage; `cd backend && go test ./...` bleibt grün.
- iOS: `xcodebuild build` schlägt lokal auf macOS Tahoe fehl (Apple-ld-Bug, verifiziert 2026-11-09). Reine Logik deshalb im Package, getestet mit `cd ios/Packages/FieldworksGeo && swift test`. App-Target-Tests werden geschrieben und von Jo per Xcode `Cmd+Shift+U` + `bash scripts/test-ios-no-build.sh` am Phasenende ausgeführt.
- UI-Arbeit folgt `.claude/rules/ACCESSIBILITY-IOS.md` und `DESIGN-SYSTEM.md` (Tokens, Atoms, AX5, VoiceOver-Labels).
- Ortus-Endpoint konfigurierbar: Backend `ORTUS_BASE_URL` (leer ⇒ Anreicherung aus, ein Warn-Log beim Start), App `AppConfig.ortusEndpointURL` (leer ⇒ keine Online-Abfrage, Verhalten wie offline).
- Ortus-Referenz: `../ortus/docs/reference/http-api.md`; Admin-Level-YAML: `../geopackages/osm-data/admin_levels_west_palearctic.yaml`.

## Review Focus

1. **Ortus nicht erreichbar / Timeout / 5xx** – Speichern und Sync gehen weiter, das Sample bleibt `pending`/`inherited`, kein Crash, kein leerer Placemark. Tests: Task 4 (Wrapper-Fehler), Task 8 (Enricher lässt Sample unverändert), Task 15 (App fällt auf Offline-Pfad zurück).
2. **Koordinate außerhalb jeder Admin-Abdeckung (Meer) oder außerhalb Deutschlands** – `admin`-Block `null` ⇒ kein Placemark, Status bleibt `pending`; MTB-Spalten leer, kein Fehler. Tests: Task 5, Task 3.
3. **Land fehlt in der Label-Tabelle** – Mapping fällt auf `equivalent` zurück, Label auf rohes `local_term`, dann generischen Typ. Tests: Task 1, Task 5, Task 13.
4. **Manuell geänderter Ort + spätere Backend-Anreicherung** – nichts wird überschrieben, nur `placemark_suggestion` gesetzt. Tests: Task 8.
5. **Höhe 0 m (Meeresniveau) bzw. GPS-Höhe vorhanden** – Vorhandensein einer Höhe wird über `elevation_source != ""` entschieden, nicht über `elevation != 0`; DEM ersetzt nie GPS/manuell. Tests: Task 8, Task 15.

---

## Phase O1 – Backend

### Task 0: Phasenstatus eintragen

**Files:** Modify: `PHASES.md` (Kopfzeile „Aktive Phase“ + neuer Abschnitt `## Phase O – Ortus-Ortsdaten am Sample` mit Status `in progress`, Link auf Spec und Plan, Aufgabenliste = Tasks dieses Plans).

- [ ] **Step 1:** Abschnitt anlegen, Kopfzeile anpassen.
- [ ] **Step 2: Commit** `docs(phases): Phase O (Ortus) gestartet`

### Task 1: Label-Tabelle – Format, Generator, Go-Loader

**Files:**
- Create: `backend/cmd/adminlabels-gen/main.go`
- Create: `shared/admin-labels/admin_labels.json` (generiert, kanonisch)
- Create: `backend/internal/adminlabels/admin_labels.json` (Kopie), `backend/internal/adminlabels/table.go`, `backend/internal/adminlabels/table_test.go`
- Create: `scripts/sync-admin-labels.sh` (kopiert die kanonische Datei nach Backend und – ab Task 12 – ins Swift-Package)

**Interfaces:**
- Produces:
  ```go
  type Tier string // "admin_country" … "admin_other"
  var Tiers = []Tier{"admin_country","admin_state","admin_region","admin_province","admin_county","admin_district","admin_municipality","admin_borough","admin_parish","admin_submunicipality","admin_other"}
  type LevelEntry struct { Column *Tier `json:"column"`; Term string `json:"term"` } // Column nil ⇒ Level nicht speichern
  type Country struct { Name string `json:"name"`; Reviewed bool `json:"reviewed"`; Levels map[int]LevelEntry `json:"levels"` }
  type Table struct { Version int `json:"version"`; Countries map[string]Country `json:"countries"` }
  func Default() *Table                                   // embed, panics nur bei kaputter eingebetteter Datei
  func (t *Table) Column(iso string, level int) (Tier, bool) // bool=false ⇒ (Land,Level) unbekannt
  func (t *Table) Term(iso string, level int) string        // "" wenn unbekannt
  ```
- JSON-Form: `{"version":1,"countries":{"DE":{"name":"Deutschland","reviewed":false,"levels":{"4":{"column":"admin_state","term":"Bundesland"}, "11":{"column":null,"term":"Flur"}}}}}`

**Generator-Regeln (Entwurf):** Spalte = `"admin_"+equivalent`. Teilen sich mehrere Level eines Landes einen Typ, bekommt das **niedrigste Level** die Spalte, die übrigen `column: null`. `term` = YAML-`name` unverändert (Bereinigung in Task 2). `reviewed: false` für alle. Ausgabe sortiert, 2-Space-indent, damit Diffs lesbar sind.

- [ ] **Step 1: Failing tests** in `table_test.go`:
  - `TestDefault_HasAll77Countries`: `len(Default().Countries) == 77`.
  - `TestColumn_DE`: `Column("DE",8) == ("admin_municipality", true)`, `Column("DE",4) == ("admin_state", true)`.
  - `TestColumn_CollisionLowestLevelWins`: `Column("DE",10)` → `admin_submunicipality`; `Column("DE",11)` → `("", true)` (bekannt, aber nicht gespeichert).
  - `TestColumn_UnknownCountry`: `Column("XX",8)` → `("", false)`.
  - `TestCopyMatchesShared`: Bytes von `admin_labels.json` == `../../../shared/admin-labels/admin_labels.json`.
- [ ] **Step 2:** `cd backend && go test ./internal/adminlabels/` → FAIL (Paket fehlt).
- [ ] **Step 3:** Generator schreiben (`go get gopkg.in/yaml.v3`), aufrufen: `go run ./cmd/adminlabels-gen -in ../../geopackages/osm-data/admin_levels_west_palearctic.yaml -out ../shared/admin-labels/admin_labels.json`, dann `bash scripts/sync-admin-labels.sh`. Loader mit `//go:embed admin_labels.json`.
- [ ] **Step 4:** Tests → PASS.
- [ ] **Step 5: Commit** `feat(backend): Label-Tabelle für Admin-Ebenen (Generator + Loader)`

### Task 2: Label-Tabelle – Bereinigungsentwurf aller 77 Länder

**Files:** Modify: `shared/admin-labels/admin_labels.json` (+ Sync-Kopie), Create: `backend/internal/adminlabels/curation_test.go`

Pro Land jeden `term` auf einen **Singular-Fachbegriff in der Landessprache** (lateinische Schrift; wo üblich mit der Originalschrift nicht gemischt) reduzieren: keine Klammern, keine Wiki-Hinweise, keine Englisch-Erklärungen, keine Pluralformen, bei „A / B / C“ den Begriff wählen, der für die meisten Einheiten dieses Levels gilt. Zielspalten korrigieren, wo die YAML gleiche Rollen verschieden typisiert (z. B. IT 4 → `admin_state`, „Regione“; ES 4 → `admin_state`, „Comunidad autónoma“; ES 6 → `admin_province`, „Provincia“; ES 8 „Municipio“; DE 6 „Landkreis“, DE 8 „Gemeinde“). Doppelungen bewusst entscheiden (PL 7 „Gmina“ → `admin_municipality`, PL 8 → `null`; CY analog). `reviewed` bleibt `false` – Jo nimmt pro Land ab.

- [ ] **Step 1: Failing tests** in `curation_test.go`:
  - `TestTerms_NoWikiArtifacts`: kein `term` enthält `(`, `)`, `[[`, `NUTS`, `fixme`, `derived from data`, `n/a`.
  - `TestTerms_Samples`: `Term("ES",4)=="Comunidad autónoma"`, `Term("IT",4)=="Regione"`, `Column("IT",4)=="admin_state"`, `Term("DE",8)=="Gemeinde"`.
  - `TestColumns_UniquePerCountry`: pro Land höchstens ein Level je Spalte.
- [ ] **Step 2:** `go test ./internal/adminlabels/` → FAIL.
- [ ] **Step 3:** JSON bereinigen, Sync-Skript laufen lassen.
- [ ] **Step 4:** Tests → PASS.
- [ ] **Step 5: Commit** `feat(backend): Bereinigungsentwurf der Landesbegriffe (77 Länder, ungeprüft)`

### Task 3: TK25-Quadrant (Go)

**Files:** Create: `backend/internal/mtb/tk25.go`, `backend/internal/mtb/tk25_test.go`, `shared/testdata/tk25_cases.json`

**Interfaces:** Produces `func Cell(lat, lon float64) (row, col, quadrant int, ok bool)` – Zeile ab 55°54′ N in 0,1°-Schritten (`row = floor((55.9-lat)*10)+1`), Spalte ab 5°50′ O in 1/6°-Schritten (`col = floor((lon-35.0/6)*6)+1`), Quadrant 1=NW, 2=NO, 3=SW, 4=SO aus der Lage in der Zelle; `ok=false` außerhalb `47.0 ≤ lat ≤ 55.9`, `5.8334 ≤ lon ≤ 15.5`.

`shared/testdata/tk25_cases.json`: `[{"lat":49.6623256519365,"lon":10.0716428069229,"row":63,"col":26,"quadrant":1},{"lat":49.681616,"lon":10.039652,"row":63,"col":26,"quadrant":1},{"lat":49.61,"lon":10.15,"row":63,"col":26,"quadrant":4},{"lat":49.69,"lon":10.15,"row":63,"col":26,"quadrant":2},{"lat":49.61,"lon":10.01,"row":63,"col":26,"quadrant":3},{"lat":40.0,"lon":3.0,"ok":false}]` (`ok` fehlt ⇒ true).

- [ ] **Step 1:** `TestCell_SharedCases` liest die JSON-Datei und prüft alle Fälle.
- [ ] **Step 2:** `go test ./internal/mtb/` → FAIL.
- [ ] **Step 3:** `Cell` implementieren.
- [ ] **Step 4:** PASS.
- [ ] **Step 5: Commit** `feat(backend): TK25-Quadrant aus Koordinate berechnen`

### Task 4: Ortus-Wrapper

**Files:** Create: `backend/internal/services/ortus.go`, `backend/internal/services/ortus_test.go`, `shared/testdata/ortus/query_de_ochsenfurt.json`, `shared/testdata/ortus/query_es_lapalma.json`, `shared/testdata/ortus/query_sea.json`

**Interfaces:**
- Consumes: `doWithRetry`, `Geocache`, `CoordinateKey` (bestehend in `internal/services`).
- Produces:
  ```go
  type OrtusResponse struct {
      WGS84     *struct{ Lon, Lat float64 }     `json:"wgs84"`
      Results   []OrtusSourceResult             `json:"results"`
      Gazetteer *OrtusGazetteer                 `json:"gazetteer"`
  }
  type OrtusSourceResult struct { SourceID string `json:"source_id"`; SourceName string `json:"source_name"`; Features []OrtusFeature `json:"features"`; License json.RawMessage `json:"license"` }
  type OrtusFeature struct { ID json.RawMessage `json:"id"`; Layer string `json:"layer"`; Properties map[string]any `json:"properties"` }
  type OrtusGazetteer struct {
      Admin     *struct{ CountryISO string `json:"country_iso"`; Hierarchy []OrtusAdminUnit `json:"hierarchy"` } `json:"admin"`
      Islands   []OrtusNamed `json:"islands"`
      Mountains *struct{ Mountain, Range *OrtusNamed } `json:"mountains"` // json-Tags "mountain","range"
      Bearing   *OrtusBearing   `json:"bearing"`
      Exposure  *OrtusExposure  `json:"exposure"`
      Elevation *OrtusElevation `json:"elevation"`
  }
  type OrtusAdminUnit struct { Level int; Name, NameNative, Equivalent, LocalTerm string } // snake_case-Tags
  type OrtusNamed struct { Name, NameNative string }
  type OrtusBearing struct { Label, Reference, Compass string; DistanceKm float64; Inside bool }
  type OrtusExposure struct { SlopeDeg float64; AspectDeg *float64; AspectCompass string; Flat bool }
  type OrtusElevation struct { Meters, AccuracyM float64; SeaLevel bool }
  type Ortus struct { BaseURL string; HTTPClient *http.Client; Cache *Geocache; MaxRetries int }
  func (o *Ortus) Query(ctx context.Context, lat, lon float64) (*OrtusResponse, error) // GET {BaseURL}/api/v1/query?lon=&lat=
  ```
  Cache: Service-Name `"ortus"`, Schlüssel `CoordinateKey(lat, lon, "")`. Testdaten-JSONs sind realistische Antworten nach `http-api.md` (DE: Ochsenfurt-Hierarchie Level 2/4/5/6/8 + `tk25-blattschnitt-de` mit `{"id":"6326","dtknummer":"6326","blattname":"Ochsenfurt"}` + eine zweite Quelle; ES: Level 2/4/6/8 + Insel „La Palma“; Meer: `admin: null`, `results: []`).

- [ ] **Step 1: Failing tests** (httptest-Server liefert die Testdaten): `TestOrtusQuery_DecodesDE` (Hierarchie-Länge, `CountryISO=="DE"`, TK25-Feature vorhanden), `TestOrtusQuery_CachesSecondCall` (Server-Hits == 1 nach zwei Aufrufen), `TestOrtusQuery_5xxRetriesThenErrors`, `TestOrtusQuery_SeaPointAdminNil`.
- [ ] **Step 2:** `go test ./internal/services/ -run Ortus` → FAIL.
- [ ] **Step 3:** Implementieren; Log mit `service=ortus`, `cache`, `duration_ms`.
- [ ] **Step 4:** PASS.
- [ ] **Step 5: Commit** `feat(backend): Ortus-Client mit Retry und Cache`

### Task 5: Mapping Ortus → Place / SampleGeo / Features

**Files:** Create: `backend/internal/geoplace/place.go`, `map.go`, `hash.go`, `*_test.go`, `shared/testdata/ortus/expected_*.json`

**Interfaces:**
- Consumes: `adminlabels.Table`, `services.OrtusResponse`, `mtb.Cell`.
- Produces:
  ```go
  type AdminValue struct { Name, Native string; Level int }
  type Place struct { CountryISO string; Admin map[adminlabels.Tier]AdminValue; Island, MountainRange, Mountain string }
  type SampleGeo struct {
      ElevationDEM, ElevationDEMAccuracy *float64
      SlopeDeg, AspectDeg *float64; AspectCompass string; TerrainFlat bool
      BearingLabel, BearingReference, BearingCompass string; BearingDistanceKm *float64; BearingInside bool
      MTBSheetNumber, MTBSheetName string; MTBQuadrant int // 0 ⇒ keiner
  }
  type Feature struct { SourceID, SourceName, Layer, FeatureID string; Properties map[string]any; License json.RawMessage }
  type Result struct { Place *Place /* nil ⇒ keine Admin-Abdeckung */; Geo SampleGeo; Features []Feature }
  func FromOrtus(r *services.OrtusResponse, lat, lon float64, t *adminlabels.Table) Result
  func (p Place) DedupHash() string
  ```
- **Mapping-Regel:** Für jede Hierarchie-Einheit `col, known := t.Column(iso, level)`; `known && col != ""` ⇒ Spalte setzen; `!known` ⇒ Fallback `"admin_"+equivalent`, aber nur wenn diese Spalte noch frei ist. Belegen zwei Einheiten dieselbe Spalte, gewinnt das niedrigere Level. Insel = erster Eintrag von `islands`. MTB nur bei `CountryISO=="DE"`, aus Quelle `tk25-blattschnitt-de` (`id` → Nummer, `blattname` → Name), Quadrant aus `mtb.Cell`. `elevation.sea_level` ⇒ `ElevationDEM = 0`.
- **Hash:** SHA-256 hex über `|`-verbundene, NFC-normalisierte, kleingeschriebene, getrimmte Werte in fester Reihenfolge: `CountryISO`, die elf Tiers in `adminlabels.Tiers`-Reihenfolge (nur `Name`), `Island`, `MountainRange`, `Mountain`. Der Hash-Testvektor (`expected_de_ochsenfurt.json` enthält `"dedup_hash"`) ist für Go und Swift identisch.

- [ ] **Step 1: Failing tests:** `TestFromOrtus_DE` vergleicht gegen `expected_de_ochsenfurt.json` (Place-Spalten, MTB `6326`/`Ochsenfurt`/Quadrant, Feature-Anzahl, Hash); `TestFromOrtus_ESIsland` (`admin_state=="Canarias"`, `Island=="La Palma"`, MTB leer); `TestFromOrtus_SeaNoPlace` (`Place==nil`); `TestFromOrtus_UnknownCountryFallsBackToEquivalent` (Tabelle ohne Land, Level 8 `municipality` ⇒ `admin_municipality`); `TestDedupHash_StableAndCaseInsensitive`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implementieren.
- [ ] **Step 4:** PASS; `go test -cover ./internal/geoplace/` > 80 %.
- [ ] **Step 5: Commit** `feat(backend): Ortus-Antwort auf flache Ortsspalten abbilden`

### Task 6: Migrationen – Placemarks, Samples, Sample-Features

**Files:** Create: `backend/migrations/1700000023_phase_o_placemarks_ortus.go`, `1700000024_phase_o_samples_ortus.go`, `1700000025_phase_o_sample_features.go`, je `_test.go`.

- `placemarks`: neue Spalten `country_iso` (text), je Tier `admin_<tier>` (text), `admin_<tier>_level` (number), `admin_<tier>_native` (text), `island`, `mountain_range`, `mountain` (text), `owner` (relation users, optional). `geocoding_source`-Optionen → `backend_service`,`manual`; **Bestandsmigration** `UPDATE placemarks SET geocoding_source='backend_service' WHERE geocoding_source='backend-service'`. Bestehenden Unique-Index auf `dedup_hash` ersetzen durch nicht-unique `(dedup_hash, geocoding_source, owner)`-Index (Eindeutigkeit garantiert `LookupOrCreate`, vgl. Phase-3b-Lehre). Rules: List/View `@request.auth.id != '' && (owner = '' || owner = @request.auth.id)`; Create/Update/Delete `nil`. Legacy-Spalten bleiben bis O3.
- `samples`: Feld `altitude` → `elevation` umbenennen (Feld-ID erhalten); neu: `elevation_source`, `location_status` (select, Default-Backfill `pending`; Samples mit vorhandenem `mtb` ⇒ ebenfalls `pending`, damit der Backfill sie erfasst), `placemark`, `placemark_suggestion` (relation placemarks), `mtb_sheet_number`, `mtb_sheet_name` (text), `mtb_quadrant`, `elevation_dem`, `elevation_dem_accuracy`, `slope_deg`, `aspect_deg`, `bearing_distance_km` (number), `aspect_compass`, `bearing_label`, `bearing_reference`, `bearing_compass` (text), `terrain_flat`, `bearing_inside` (bool). Samples mit nicht-leerer `altitude` ⇒ `elevation_source='location_service'`.
- `sample_features`: `owner` (relation users, required), `sample` (relation samples, cascade delete), `source_id`, `source_name`, `layer`, `feature_id` (text), `properties`, `license` (json), `fetched_at` (date); Index `(sample, source_id)`; Rules owner-scoped (`owner = @request.auth.id`) für List/View, Create/Update/Delete `nil`.

- [ ] **Step 1: Failing tests:** pro Migration ein Test mit `tests.NewTestApp()`, der Schema-Felder prüft; `TestPlacemarksMigration_RenamesBackendService` (Zeile mit `backend-service` vorher ⇒ `backend_service` nachher); `TestSamplesMigration_AltitudeBecomesElevation` (Wert bleibt erhalten, `elevation_source=='location_service'`).
- [ ] **Step 2:** FAIL. **Step 3:** Migrationen schreiben; alle bestehenden Lese-/Schreibstellen von `altitude` im Backend auf `elevation` umstellen (`internal/api/labels.go`, `export.go`, Tests). **Step 4:** `go test ./...` PASS.
- [ ] **Step 5: Commit** `feat(backend)!: Schema für Ortus-Ortsdaten, altitude → elevation` mit Footer `BREAKING CHANGE: samples.altitude heißt jetzt elevation; geocoding_source-Wert backend-service heißt backend_service.`

### Task 7: Placemark- und Feature-Store + Endpoints

**Files:** Create: `backend/internal/geoplace/store.go`, `store_test.go`; Modify: `backend/internal/api/placemark.go` (+ Test), Create: `backend/internal/api/sample_features.go` (+ Test); Modify: `docs/openapi.yaml`.

**Interfaces:**
- Consumes: `Place`, `Feature`, `DedupHash` (Task 5); Schema (Task 6).
- Produces:
  ```go
  func LookupOrCreatePlacemark(dao *daos.Dao, p Place, source, ownerID string) (*models.Record, error) // ownerID "" für backend_service
  func PlaceFromRecord(rec *models.Record) Place
  func ApplyPlace(rec *models.Record, p Place)
  func ReplaceFeatures(dao *daos.Dao, sampleID, ownerID string, fs []Feature) error // in einer Transaktion
  func ApplyGeo(rec *models.Record, g SampleGeo)
  ```
- `POST /api/placemarks/resolve` (auth): Body `{"geocoding_source":"backend_service"|"manual","country_iso":"ES","admin_state":"Canarias","admin_state_level":4, … ,"island":"La Palma"}` → 200 `{"id":"…"}` + vollständiger Record. `manual` ⇒ `owner = auth`. Ungültige `geocoding_source` ⇒ 400.
- `PUT /api/samples/:id/features` (auth, Sample muss dem User gehören, sonst 404): Body `{"features":[{"source_id":…,"source_name":…,"layer":…,"feature_id":…,"properties":{…},"license":{…}}]}` → 204; ersetzt den kompletten Satz.
- Bestehender Override `PATCH /api/localities/:id/placemark` nimmt dieselben flachen Felder wie `/resolve` (statt `administrative_area` usw.) und nutzt `LookupOrCreatePlacemark(…, "manual", owner)`.

- [ ] **Step 1: Failing tests:** `TestLookupOrCreate_ReusesSameHash`, `TestLookupOrCreate_ManualScopedPerOwner` (zwei Owner ⇒ zwei Records), `TestReplaceFeatures_ReplacesSet`, `TestResolveEndpoint_ManualSetsOwner`, `TestFeaturesEndpoint_ForeignSample404`.
- [ ] **Step 2:** FAIL. **Step 3:** Implementieren, Routen in `main.go` registrieren, OpenAPI ergänzen. **Step 4:** PASS.
- [ ] **Step 5: Commit** `feat(backend): Endpoints zum Auflösen von Ortsdaten und Ersetzen von Features`

### Task 8: Sample-Anreicherung über Ortus

**Files:** Modify: `backend/internal/enrichment/enrichment.go`, `enrichment_test.go`, `fieldtrip.go`; Modify: `backend/main.go`.

**Interfaces:**
- Consumes: `services.Ortus`, `geoplace.FromOrtus/LookupOrCreatePlacemark/ApplyPlace/ApplyGeo/ReplaceFeatures`, `adminlabels.Default()`.
- `Enricher` verliert `Labelloc`/`MTB`, bekommt `Ortus *services.Ortus` und `Labels *adminlabels.Table`. Hooks: `OnRecordAfterCreateRequest("samples")` und `OnRecordAfterUpdateRequest("samples")` (letzterer nur, wenn sich `latitude` oder `longitude` um mehr als `1e-7` geändert hat). Beide starten `go e.runSafely(id, ftID)`.
- **Regeln in `run`:**
  - Keine Koordinate (`lat==0 && lon==0`) oder Status `backend_service` ⇒ nur Fieldtrip-Derived, sonst nichts.
  - Ortus-Fehler ⇒ Warn-Log, Sample unverändert.
  - `Result.Place == nil` ⇒ Status bleibt, nur Geo + Features schreiben.
  - Status `pending`/`inherited` ⇒ Placemark `LookupOrCreate(…,"backend_service","")`, `placemark` setzen, `placemark_suggestion` leeren, Status `backend_service`.
  - Status `manual` ⇒ Kandidat anlegen; Hash ≠ aktueller Placemark ⇒ `placemark_suggestion = Kandidat`, sonst leeren. `placemark` bleibt.
  - Immer: `ApplyGeo`, `ReplaceFeatures`.
  - **Höhe:** nur wenn `elevation_source == ""` und `ElevationDEM != nil` ⇒ `elevation`, `elevation_source='backend_service'`, `vertical_accuracy = ElevationDEMAccuracy`.
- `fieldtrip.go`: `maybePropagateToFieldtrip`, Titel-Hochstufung und das Setzen von `country`/`admin_area` entfallen; Astro, Zentroid, `suggested_locality` bleiben.
- `main.go`: `ORTUS_BASE_URL` lesen; leer ⇒ `slog.Warn("ortus: ORTUS_BASE_URL leer, Anreicherung deaktiviert")` und Enricher ohne Ortus.

- [ ] **Step 1: Failing tests** (httptest-Ortus mit den Testdaten aus Task 4): `TestEnrich_PendingGetsPlacemarkFeaturesMTB`, `TestEnrich_InheritedDifferentPlaceSplits` (Sample hatte Placemark A, Ortus liefert B ⇒ Placemark B), `TestEnrich_ManualOnlySuggestion`, `TestEnrich_BackendServiceSkipped` (0 Ortus-Hits), `TestEnrich_OrtusDownLeavesSample`, `TestEnrich_DEMOnlyWhenNoElevationSource` (GPS-Höhe 0 m mit `location_service` bleibt 0; leere Quelle ⇒ DEM), `TestEnrich_CoordUpdateRetriggers`, `TestEnrich_NotesUpdateDoesNotRetrigger`.
- [ ] **Step 2:** FAIL. **Step 3:** Implementieren. **Step 4:** PASS.
- [ ] **Step 5: Commit** `feat(enrichment): Samples über Ortus anreichern`

### Task 9: Locality-Placemark über Ortus

**Files:** Modify: `backend/internal/enrichment/placemark.go`, `placemark_test.go`.

`PlacemarkEnricher` nutzt `Ortus` + `geoplace` statt `Labelloc`; `lookupOrCreatePlacemark`/`PlacemarkDedupHash` (alt) entfallen zugunsten von `geoplace.LookupOrCreatePlacemark`. Manual-Schutz bleibt.

- [ ] **Step 1:** Bestehende Tests auf Ortus-Fake umstellen + `TestLocalityPlacemark_SharesRecordWithSample` (gleiche Koordinate ⇒ gleiche Placemark-ID wie beim Sample).
- [ ] **Step 2:** FAIL. **Step 3:** Umstellen. **Step 4:** PASS.
- [ ] **Step 5: Commit** `refactor(enrichment): Locality-Placemark über Ortus`

### Task 10: labelloc/MTB entfernen, Leser umstellen

**Files:** Delete: `backend/internal/services/labelloc.go`, `labelloc_test.go`, `mtb.go`; Modify: `backend/main.go`, `backend/internal/api/labels.go` (+Test), `backend/internal/api/export.go` (+Test), `CLAUDE.md` (Abschnitt „Externe Services“ auf Ortus umschreiben).

- `labels.go`: `sampleToLabel` liest `Country`/`AdminArea`/`Locality` aus dem Placemark des Samples (`admin_country`, `admin_state`, `admin_municipality`), Höhe aus `elevation`; MTB-Felder werden **nicht** mehr gefüllt. `decodeAdminUnits`/`decodeMTB` entfallen.
- `export.go`: exportiert zusätzlich `placemarks` (die referenzierten) und `sample_features` des Owners.

- [ ] **Step 1: Failing tests:** `TestSampleToLabel_UsesPlacemark` (Land/Bundesland/Stadt aus Placemark, `MTBSheetNumber==""`), `TestExport_IncludesFeaturesAndPlacemarks`.
- [ ] **Step 2:** FAIL. **Step 3:** Umsetzen, toten Code löschen. **Step 4:** `go test ./...`, `go vet ./...` PASS; `grep -rn labelloc backend/` leer (außer Migrationen).
- [ ] **Step 5: Commit** `refactor(backend)!: labelloc und MTB-Dienst durch Ortus ersetzt`

### Task 11: Phase O1 abschließen

- [ ] **Step 1:** `docker compose up --build` mit `ORTUS_BASE_URL` auf eine erreichbare Ortus-Instanz (sonst lokale Ortus-Instanz aus `../ortus` per `docker compose` mit `tk25-blattschnitt-de.gpkg` und Gazetteer starten). Sample per REST anlegen (`location_status` leer ⇒ `pending`) und prüfen: Placemark gesetzt, Features vorhanden, `mtb_sheet_number=6326`, `mtb_quadrant=1` für 49.681616/10.039652.
- [ ] **Step 2:** `PHASES.md` O1 auf done, Demo-Notiz. **Stop – Demo an Jo.**
- [ ] **Step 3: Commit** `docs(phases): Phase O1 (Backend) abgeschlossen`

---

## Phase O2 – iOS

### Task 12: Swift-Package `FieldworksGeo` – Label-Tabelle und TK25

**Files:** Create: `ios/Packages/FieldworksGeo/Package.swift` (Library `FieldworksGeo`, platforms `.iOS(.v17)`, `.macOS(.v14)`, Resource `Resources/admin_labels.json`), `Sources/FieldworksGeo/AdminLabelTable.swift`, `TK25.swift`, `Tests/FieldworksGeoTests/AdminLabelTableTests.swift`, `TK25Tests.swift`; Modify: `scripts/sync-admin-labels.sh` (Ziel Package-Resource), `ios/project.yml` (`packages: FieldworksGeo: path: Packages/FieldworksGeo`, Dependency im App-Target).

**Interfaces:**
```swift
public enum AdminTier: String, CaseIterable, Codable, Sendable { case country = "admin_country", state = "admin_state", region = "admin_region", province = "admin_province", county = "admin_county", district = "admin_district", municipality = "admin_municipality", borough = "admin_borough", parish = "admin_parish", submunicipality = "admin_submunicipality", other = "admin_other" }
public struct AdminLabelTable: Sendable {
    public static let shared: AdminLabelTable
    public func column(country: String, level: Int) -> (tier: AdminTier?, known: Bool)
    public func term(country: String, level: Int) -> String?
    public func levels(country: String) -> [(level: Int, tier: AdminTier, term: String)] // nach Level sortiert, nur mit Spalte
    public var countries: [(iso: String, name: String)]
}
public enum TK25 { public static func cell(lat: Double, lon: Double) -> (row: Int, col: Int, quadrant: Int)? }
```
- [ ] **Step 1: Failing tests:** Spiegel von Task 1/2/3: `testHas77Countries`, `testColumnDE`, `testCollision`, `testUnknownCountry`, `testResourceMatchesShared` (liest `shared/admin-labels/admin_labels.json` relativ zu `#filePath`), `testTK25SharedCases` (liest `shared/testdata/tk25_cases.json`).
- [ ] **Step 2:** `cd ios/Packages/FieldworksGeo && swift test` → FAIL.
- [ ] **Step 3:** Implementieren, Sync-Skript laufen lassen.
- [ ] **Step 4:** `swift test` PASS.
- [ ] **Step 5: Commit** `feat(ios): FieldworksGeo-Package mit Label-Tabelle und TK25`

### Task 13: Swift – Ortus-Modelle, Mapping, Hash, Labels

**Files:** Create in `ios/Packages/FieldworksGeo/Sources/FieldworksGeo/`: `OrtusResponse.swift`, `Place.swift`, `OrtusMapper.swift`, `PlaceLabels.swift`; Tests `OrtusMapperTests.swift`, `PlaceLabelsTests.swift`.

**Interfaces (Spiegel von Task 4/5):**
```swift
public struct OrtusResponse: Decodable, Sendable { … }   // gleiche Felder wie Go, snake_case-CodingKeys
public struct AdminValue: Codable, Equatable, Sendable { public var name: String; public var native: String; public var level: Int }
public struct Place: Codable, Equatable, Sendable { public var countryISO: String; public var admin: [AdminTier: AdminValue]; public var island, mountainRange, mountain: String; public var dedupHash: String { get } }
public struct SampleGeo: Equatable, Sendable { … }        // gleiche Felder wie Go
public struct OrtusFeature: Codable, Equatable, Sendable { public var sourceID, sourceName, layer, featureID: String; public var propertiesJSON: String; public var licenseJSON: String? }
public struct OrtusResult: Sendable { public var place: Place?; public var geo: SampleGeo; public var features: [OrtusFeature] }
public enum OrtusMapper { public static func map(_ r: OrtusResponse, lat: Double, lon: Double, table: AdminLabelTable = .shared) -> OrtusResult }
public struct PlaceFieldLabel: Equatable, Sendable { public var term: String?; public var genericKey: String } // genericKey z. B. "admin.state"
public enum PlaceLabels { public static func label(country: String?, tier: AdminTier, level: Int?, rawLocalTerm: String?, table: AdminLabelTable = .shared) -> PlaceFieldLabel }
```
Label-Fallback: Tabelle(Land, Level) → `rawLocalTerm` → `term = nil` (nur generischer Schlüssel). Generische Schlüssel `admin.country` … `admin.other`, `place.island`, `place.mountain_range`, `place.mountain`.

- [ ] **Step 1: Failing tests:** gleiche Testdaten wie Go (`shared/testdata/ortus/*.json`): `testMapDE` gegen `expected_de_ochsenfurt.json` **inkl. identischem `dedup_hash`**, `testMapESIsland`, `testMapSeaNoPlace`, `testUnknownCountryFallback`, `testLabelFallbackChain`.
- [ ] **Step 2:** `swift test` FAIL. **Step 3:** Implementieren. **Step 4:** PASS.
- [ ] **Step 5: Commit** `feat(ios): Ortus-Mapping und Feld-Labels im FieldworksGeo-Package`

### Task 14: GRDB-Migration v13 und Stores

**Files:** Modify: `ios/Fieldworksdiary/Core/Persistence/Database.swift` (`v13_ortus_location`), `LocalSample.swift`, `LocalPlacemark.swift`, `LocalSampleStore.swift`; Create: `LocalSampleFeature.swift`, `LocalSampleFeatureStore.swift`, `LocalPlacemarkStore.swift` (falls nicht vorhanden, sonst erweitern); Tests: `FieldworksdiaryTests/LocalPlacemarkStoreTests.swift`, `LocalSampleFeatureStoreTests.swift`, `DatabaseMigrationV13Tests.swift`.

- `local_samples`: neue Spalten `elevation` (Werte aus `altitude` kopiert), `elevation_source`, `location_status` (Default `pending`), `placemark`, `placemark_suggestion`, `mtb_quadrant`, `elevation_dem`, `elevation_dem_accuracy`, `slope_deg`, `aspect_deg`, `aspect_compass`, `terrain_flat`, `bearing_label`, `bearing_reference`, `bearing_distance_km`, `bearing_compass`, `bearing_inside`. Swift-Property `altitude` → `elevation`.
- `local_placemarks`: neue Spalten analog Backend (`country_iso`, je Tier Name/Level/Native, `island`, `mountain_range`, `mountain`, `owner`, `backend_id`), `UPDATE … SET geocoding_source='backend_service' WHERE geocoding_source='backend-service'`. `Placemark.GeocodingSource` decodiert beide Schreibweisen, schreibt `backend_service`.
- `local_sample_features`: `id`, `sample_id` (lokale UUID), `source_id`, `source_name`, `layer`, `feature_id`, `properties_json`, `license_json`, `fetched_at`.
- Produces: `LocalPlacemarkStore.lookupOrCreate(place: Place, source: Placemark.GeocodingSource) throws -> LocalPlacemark` (Dedup über `dedupHash` + Quelle), `LocalSampleFeatureStore.replace(sampleID: String, features: [OrtusFeature]) throws`, `features(sampleID: String, sourceID: String) throws -> [LocalSampleFeature]`, `LocalSampleStore.latestPlacemarkID(collectingDay: String, excluding: String) throws -> String?`.

- [ ] **Step 1: Failing tests** schreiben (Migration erhält `altitude`-Wert als `elevation`; `backend-service` wird umbenannt; lookupOrCreate dedupliziert; replace ersetzt; latestPlacemarkID).
- [ ] **Step 2–4:** Implementieren. Ausführung durch Jo (`Cmd+Shift+U`, `bash scripts/test-ios-no-build.sh`) am Phasenende – der Implementer notiert im Bericht, dass sie ungelaufen sind.
- [ ] **Step 5: Commit** `feat(ios): lokale Persistenz für Ortsdaten und Features`

### Task 15: Ortus-Client und Ortsauflösung beim Anlegen

**Files:** Create: `ios/Fieldworksdiary/Core/Ortus/OrtusClient.swift`, `ios/Fieldworksdiary/Core/Geo/SampleLocationResolver.swift`; Modify: `Core/Config/AppConfig.swift` (`@Published var ortusEndpointURL: String`, UserDefaults-Key `ortusEndpointURL`), Settings-Screen (Feld „Ortus-Endpoint“), `Features/SampleEditor/SampleEditorViewModel.swift`, `Core/Location/LocationProvider.swift` (vertikale Genauigkeit durchreichen); Tests `FieldworksdiaryTests/SampleLocationResolverTests.swift`.

**Interfaces:**
```swift
protocol OrtusQuerying { func query(lat: Double, lon: Double) async throws -> OrtusResponse }
struct OrtusClient: OrtusQuerying { let endpoint: String; let timeout: TimeInterval = 5 }
@MainActor final class SampleLocationResolver {
    init(ortus: OrtusQuerying?, samples: LocalSampleStore, placemarks: LocalPlacemarkStore, features: LocalSampleFeatureStore)
    func resolveOnline(sampleID: String) async -> Bool      // true ⇒ Status backend_service
    func inheritOffline(sampleID: String) throws            // Placemark vom vorigen Sample des Tages, Status inherited
}
```
- Regeln: Nach GPS-Fix wird gespeichert (`elevation`, `elevation_source = location_service`, wenn das GPS eine Höhe liefert; `vertical_accuracy`, `horizontal_accuracy`, `location_source = location_service`), dann `resolveOnline`; bei `false` ⇒ `inheritOffline`. Manuelle Koordinate ⇒ `location_source = user` (Bugfix: bisher `location_service` im Push). DEM-Höhe nur bei `elevation_source == nil`. Ortus-Timeout 5 s, blockiert nie das Speichern.

- [ ] **Step 1: Failing tests** mit Fake-`OrtusQuerying`: Online-Erfolg setzt Placemark/Features/MTB/Status; Fehler ⇒ inherited vom vorigen Sample; kein voriges Sample ⇒ pending; GPS-Höhe 0 m bleibt; manuelle Koordinate ohne Höhe ⇒ DEM + `backend_service`.
- [ ] **Step 2–4:** Implementieren (Lauf durch Jo).
- [ ] **Step 5: Commit** `feat(ios): Ortsdaten beim Anlegen sofort über Ortus`

### Task 16: Sync – Placemark, Sample, Features

**Files:** Modify: `Core/Sync/SyncRunner.swift`, `Core/PocketBaseClient/SampleClient.swift`, `Core/Models/Sample.swift`, `Core/Persistence/LocalSampleStore.swift` (Hydration), `Core/Sync/SamplesHydrator.swift`; Create: `Core/PocketBaseClient/PlacemarkClient.swift`, `SampleFeaturesClient.swift`; Tests: `SyncRunnerTests.swift` (erweitern), `SyncRunnerOrtusTests.swift`.

- Create-Pfad: (1) hat das Sample einen lokalen Placemark ohne `backendId` ⇒ `POST /api/placemarks/resolve`, `backendId` merken; (2) `createSample` schickt zusätzlich `elevation`, `elevation_source`, `vertical_accuracy`, `location_source` (echter Wert), `location_status`, `placemark`, `locality`, MTB- und Gelände-Felder; (3) lokale Features vorhanden ⇒ `PUT /api/samples/:id/features`.
- **Bugfix:** `working.locality = created.locality` überschreibt eine lokal gesetzte Locality nicht mehr mit leer.
- Update-Pfad: `SampleUpdateInput` um Koordinaten-, Höhen-, Orts- und Statusfelder erweitern (gleiche Reihenfolge Placemark → PATCH → Features).
- Hydration: neue Sample-Felder, referenzierte Placemarks (`/api/collections/placemarks/records?filter=id in …`) und Features für Samples mit Status `backend_service` ohne lokale Features (`/api/collections/sample_features/records?filter=sample='…'`). `pollEnrichment` prüft `location_status == backend_service` statt `adminUnits`.
- `adminUnits` aus `Sample.swift` entfernen.

- [ ] **Step 1: Failing tests** (Mock-Clients): Reihenfolge resolve → create → features; Locality bleibt erhalten; offline angelegtes Sample bekommt nach Hydration Placemark + Features; Update mit neuer Koordinate schickt `location_status`.
- [ ] **Step 2–4:** Implementieren (Lauf durch Jo).
- [ ] **Step 5: Commit** `feat(sync): Ortsdaten und Features synchronisieren`

### Task 17: UI – Ortsfelder anzeigen, bearbeiten, korrigieren, filtern

**Files:** Create: `ios/Fieldworksdiary/Core/UI/PlaceFieldRow.swift` (Atom: Landesbegriff oben, generischer Typ darunter, Wert; Previews Default/AX5/Dark; Eintrag im `DesignCatalogView`), `Features/SampleEditor/PlaceEditorView.swift`, `Features/SampleEditor/PlaceEditorViewModel.swift`; Modify: `SampleEditorView.swift`, `SampleDetailView.swift`, `SamplesListView.swift`, `CalendarView.swift`, `MarkedSamplesView.swift`, `HomeViewModel.swift`, `FieldtripDetailView.swift`, `Features/Fieldtrips/FieldtripsFilter.swift`, `FieldtripsFilterSheet.swift`, `Localizable.xcstrings`; Tests: `PlaceEditorViewModelTests.swift`, `FieldtripsFilterTests.swift` (anpassen).

- **Anzeige:** Ortsfelder des Placemarks in Level-Reihenfolge mit `PlaceLabels`; leere Felder unsichtbar; MTB als „MTB 6326/1 Ochsenfurt“ (nur DE). Listen zeigen statt `adminUnitsLocality` die Gemeinde (`admin_municipality`, sonst nächsthöhere befüllte Ebene).
- **Generische Labels (de):** `admin.country` „Staat“, `admin.state` „Gliedstaat (1. Ebene)“, `admin.region` „Region“, `admin.province` „Provinz“, `admin.county` „Kreis“, `admin.district` „Bezirk“, `admin.municipality` „Gemeinde“, `admin.borough` „Stadtbezirk“, `admin.parish` „Kirchspiel“, `admin.submunicipality` „Ortsteil“, `admin.other` „Sonstige Einheit“, `place.island` „Insel“, `place.mountain_range` „Gebirge“, `place.mountain` „Berg“.
- **Bearbeiten:** `PlaceEditorView` – erst Land (Picker aus `AdminLabelTable.countries`), dann nur dessen Ebenen (`levels(country:)`) plus Insel/Gebirge/Berg. Speichern ⇒ `lookupOrCreate(…, .manual)`, nur dieses Sample umhängen, `location_status = manual`.
- **Höhe manuell:** Eingabefeld ⇒ `elevation_source = manual`.
- **Ohne Koordinate:** Kartenpunkt ist Pflicht, bevor Ortsdaten geholt werden (`location_source = user`).
- **Koordinatenkorrektur:** Bei `location_status == manual` Dialog „Ortsangaben neu übernehmen?“ (Übernehmen / Meine Angaben behalten); sonst direkt neu holen.
- **Vorschlag vom Backend:** `placemark_suggestion` gesetzt ⇒ Hinweis „Neue Ortsangaben verfügbar“ mit Übernehmen/Verwerfen.
- **Filter:** „Land“ (aus den Placemarks der lokalen Samples) und „Ort“ (Textsuche über alle Ortsfelder); ein Fieldtrip passt, wenn eines seiner Samples passt. `LocalFieldtrip.country/adminArea` werden nicht mehr gelesen.

- [ ] **Step 1: Failing tests:** `PlaceEditorViewModelTests` (Land wählen ⇒ richtige Felder/Labels; Speichern trennt nur dieses Sample ab, Status manual); Filter-Tests (Land/Ort über Sample-Placemarks).
- [ ] **Step 2–4:** Implementieren; A11y-Grep aus `ACCESSIBILITY-IOS.md` §5 und `DESIGN-SYSTEM.md` über geänderte Dateien ⇒ 0 Treffer. `grep -rn "Placemark" Fieldworksdiary/**/*.xcstrings` ⇒ leer.
- [ ] **Step 5: Commit** `feat(ios): Ortsfelder mit Landesbegriffen anzeigen, bearbeiten und filtern`

### Task 18: Phase O2 abschließen

- [ ] **Step 1:** Jo: `Cmd+Shift+U`, `bash scripts/test-ios-no-build.sh` ⇒ alles grün; manueller Test im Simulator (online: Ort + MTB sofort; Flugmodus: Placemark vom vorigen Sample; nach Sync: Backend-Anreicherung sichtbar; Korrektur-Dialog; AX5 + VoiceOver auf Sample-Screen und `PlaceEditorView`).
- [ ] **Step 2:** `PHASES.md` O2 done. **Stop – Demo an Jo.**
- [ ] **Step 3: Commit** `docs(phases): Phase O2 (iOS) abgeschlossen`

---

## Phase O3 – Backfill und Aufräumen

### Task 19: Backfill-Kommando

**Files:** Create: `backend/internal/backfill/ortus.go`, `ortus_test.go`; Modify: `backend/main.go` (Cobra-Kommando `ortus-backfill` an `app.RootCmd`).

- Schritt A – **Legacy-manuelle Placemarks:** `country` → `country_iso`, `administrative_area` → `admin_state`, `sub_administrative_area` → `admin_county`, `locality` → `admin_municipality`, `sub_locality` → `admin_submunicipality`; `owner` aus der referenzierenden Locality; Quelle bleibt `manual`; jede Zeile `slog.Info("backfill: legacy manual placemark", …)` mit Alt- und Neuwerten (ohne Koordinaten).
- Schritt B – alle Samples mit Koordinate und Status ≠ `manual`: wie Task 8 anreichern (synchron, mit Rate-Limit 5/s), Fortschritt loggen; idempotent (zweiter Lauf ändert nichts).

- Schritt C – **Neuzuordnung nach Tabellenänderung** (Spec §4.3, auch einzeln aufrufbar als `ortus-backfill --remap-only`): Für jeden `backend_service`-Placemark aus den gespeicherten `admin_<tier>_level`-Werten mit der aktuellen Tabelle neu zuordnen (kein Ortus-Aufruf); ergibt sich ein anderer Hash, `LookupOrCreate` des neuen Placemarks und Samples/Localities umhängen. `manual` bleibt unberührt.

- [ ] **Step 1: Failing tests:** `TestBackfill_LegacyManualMapped`, `TestBackfill_SamplesEnriched`, `TestBackfill_Idempotent`, `TestBackfill_ManualSampleUntouched`, `TestRemap_ColumnChangeMovesSamples`.
- [ ] **Step 2–4:** Implementieren, PASS.
- [ ] **Step 5: Commit** `feat(backend): Backfill der Ortsdaten über Ortus`

### Task 20: Alte Spalten entfernen

**Files:** Create: `backend/migrations/1700000026_phase_o_drop_legacy_location.go` (+Test); Modify: iOS `Database.swift` (`v14_drop_legacy_location`), betroffene Modelle.

Entfernt: `placemarks.country, administrative_area, sub_administrative_area, locality, sub_locality, postal_code, name, thoroughfare`; `samples.mtb`; `fieldtrips.admin_units, mtb, country, admin_area`; iOS `local_samples.admin_units_locality, admin_units_country`, `local_fieldtrips.admin_units_json, mtb_json, country, admin_area`, alte `local_placemarks`-Spalten. Erst nach erfolgreichem Backfill in Prod deployen.

- [ ] **Step 1:** Failing Migrationstest (Spalten weg, Daten der neuen Spalten unverändert). **Step 2–4:** Implementieren, `go test ./...` PASS.
- [ ] **Step 5: Commit** `refactor!: alte Ortsspalten entfernt` mit `BREAKING CHANGE:`-Footer.
- [ ] **Step 6:** `PHASES.md` Phase O done.
