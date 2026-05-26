# Bestandsaufnahme — Sample / Locality / Placemark Refactoring

Stand: 2026-05-22 · Phase 0 nach `fieldsampling-refactoring-plan.md`.
Diese Datei ist eine **reine Faktensammlung**. Bewertung und Soll-Diff
stehen in `gap-analysis.md`.

---

## 1. Backend

### 1.1 Stack

- PocketBase als Go-Library: `github.com/pocketbase/pocketbase v0.22.14`
  (backend/go.mod:9).
- `migratecmd.MustRegister(..., Automigrate: true)` in
  backend/main.go:28 — Migrationen laufen beim Start.
- Blank-Import `_ "go.mett.io/fwd-backend/migrations"` registriert alle
  Migrationen über `init()`-Funktionen.
- Logging: `log/slog` mit JSON-Handler, Convention in
  `.claude/rules/LOGGING.md`.

### 1.2 Collections (konsolidiert aus 13 Migrationen)

#### `samples`
- `code` (Text, indiziert non-unique seit Migration 3)
- `original_code` (Text) — vom Client bei Kollision gemerkt
- `excursion` (Relation → `excursions`, max 1)
- `owner` (Relation → `users`, cascade-delete, seit Phase 11)
- `collected_from` (Date, default = `now`)
- `collected_to` (Date)
- `lat` (Number, required)
- `lon` (Number, required)
- `altitude_m`, `accuracy_m` (Number, optional)
- `notes` (Editor)
- `admin_units` (JSON, max 2 MiB) — Labelloc-Snapshot
- `mtb` (JSON, max 2 MiB) — MTB-Lookup-Snapshot
- `marked` (Boolean, default false, indiziert)
- `client_uuid` (Text), `client_updated_at` (Date) — Sync-Idempotenz
- Indexe: `idx_samples_code`, `idx_samples_excursion`,
  `idx_samples_owner`, `idx_samples_marked`.
- Rules (Phase 11): list/view/update/delete = `@request.auth.id != '' && owner = @request.auth.id`,
  createRule = `@request.auth.id != ''`.

#### `excursions`
- `name` (Text) — Hook füllt mit "Sammeltag" oder Locality-Name
- `owner` (Relation → users, cascade-delete) seit Phase 11
- `started_at`, `ended_at` (Date)
- `collecting_day` (Text, `YYYY-MM-DD`) — Hook
- `night_excursion` (Boolean) — Hook über `grouping.ExpandWindow`
- `locality` (Relation → `localities`, max 1) — manuell zuweisbar
- `suggested_locality` (Relation → `localities`, max 1, Phase 4b)
- `centroid_lat`, `centroid_lon` (Number) — Enricher recompute
- `admin_units`, `mtb`, `astro` (JSON, max 2 MiB)
- `day_of_year` (Number), `country` (Text), `admin_area` (Text) — Phase 5 denormalisiert
- `permit_number` (Text), `permit_pdf` (File, max 20 MiB) — Phase 8
- `client_uuid`, `client_updated_at` — Sync
- Indexe: `idx_excursions_owner`, `idx_excursions_owner_day`,
  `idx_excursions_doy`, `idx_excursions_country`, `idx_excursions_admin_area`.

#### `localities`
- `name` (Text, required)
- `centroid_lat`, `centroid_lon`, `radius_m` (Number)
- `notes` (Editor)
- `owner` (Relation → users, cascade-delete) Phase 11
- Indexe: `idx_localities_owner`.
- **Keine `client_uuid` / `client_updated_at`** auf dieser Collection.
- **Keine `placemark`-Relation** (Placemark-Collection existiert nicht).
- **Keine `locationSource`**.

#### `sample_sequences`
- `owner` (Relation → users)
- `collecting_day` (Text, required)
- `last_seq` (Number, required)
- Index: `idx_sample_sequences_owner_day` (unique).
- Server-internal: Rules sind nil (kein Client-Zugriff).

#### `geocache`
- `service` (Text: `labelloc` | `mtb`)
- `key` (Text, SHA-256 von `(lat, lon, lang)` mit 5-Decimal-Precision)
- `payload` (JSON, max 2 MiB)
- `cached_at` (Date)
- Indexe: `idx_geocache_service_key` (unique), `idx_geocache_cached_at`.
- DefaultTTL: 7 Tage (`services/geocache.go`).

#### `people`
- `full_name` (Text, required), `abbreviation`, `email`, `notes`
- `owner` (Relation → users) Phase 11
- Indexe: `idx_people_full_name`, `idx_people_owner`.

#### `determinations`
- `sample` (Relation → samples, required, cascade-delete)
- `species_text` (Text, required)
- `kind` (Select: `det` | `t` | `vid`, required)
- `person` (Relation → people, max 1)
- `determined_on` (Date), `notes` (Text)
- `client_uuid` (Text) — Sync
- `owner` Phase 11
- Indexe: `idx_determinations_sample`, `_kind`, `_person`, `_owner`.

#### `label_pdfs`
- `kind` (Select: `locality` | `determination`, required)
- `pdf_file` (File, max 10 MiB, PDF only, required)
- `samples` (Relation → samples, many)
- `template` (Text), `generation_params` (JSON, max 1 MiB)
- `superseded_by` (Relation → label_pdfs self, max 1) — Reprintchain
- `owner` Phase 11
- Indexe: `idx_label_pdfs_kind`, `_created`, `_owner`.

#### `sample_photos`
- `sample` (Relation → samples, required, cascade-delete) — 1:1
- `photo_file` (File, max 10 MiB, JPEG/PNG/HEIC/HEIF, required)
- `owner` (Relation → users, cascade-delete)
- `client_uuid`, `client_updated_at` — Sync
- Indexe: `idx_sample_photos_sample`, `_owner`, `_client_uuid`.

#### `users` (Built-in, erweitert Phase 11)
- Auth-Optionen: `AllowEmailAuth`, `AllowOAuth2Auth` (Apple-Sign-In),
  `RequireEmail`, `MinPasswordLength=8`.
- Zusatzfelder: `display_name`, `abbreviation`, `day_cutoff_hour`
  (0–23, default 5), `default_excursion_split_km`, `linked_person`
  (Relation → people).

### 1.3 Hooks (backend/internal/hooks/)

- `RegisterSampleCreate` (main.go:33) — `OnRecordBeforeCreateRequest("samples")`:
  1. Auth-Check über `authOwnerID()`.
  2. `collected_from` → Berlin-TZ → `codes.CollectingDay(ts, cutoff=5)` → `YYYY-MM-DD`.
  3. `grouping.FindOrCreate(repo, owner, day, ts)` → Excursion.
  4. Bei Client-Code-Reuse: `codeConflicts()` und ggf.
     `ensureSequenceAtLeast()`.
  5. `nextSequence()` atomar inkrementieren (sample_sequences, unique
     index `(owner, day)`).
  6. Fills `code`, `excursion`, `owner` auf dem Record.

- `RegisterOwnerSetters` (main.go:37) — `OnRecordBeforeCreateRequest()`
  auf `excursions`, `localities`, `people`, `determinations`,
  `sample_photos`. Setzt `owner` aus Auth-Context; validiert dass
  `incoming.owner` leer oder == auth-User-ID ist.

### 1.4 Enrichment (backend/internal/enrichment/)

- `Enricher`-Struct mit `Labelloc`-Client, `MTB`-Client, `Timeout=15s`.
- Hook `OnRecordAfterCreateRequest("samples")` startet `e.run()` in
  Goroutine mit Recover.
- `run()` ruft parallel Labelloc + MTB, schreibt JSON in
  `samples.admin_units` und `samples.mtb`.
- `maybePropagateToExcursion()` liftet `admin_units` / `mtb` /
  Locality-Name auf die Excursion **nur** wenn dort noch leer
  ("manual edits stick").
- `recomputeExcursionDerived()` berechnet `centroid_lat/lon` aus den
  Samples und füllt Phase-5-Denormalisierung
  (`day_of_year`, `country`, `admin_area`).
- `nearestLocalityID()` findet die räumlich nächste owner-scoped
  Locality und setzt `suggested_locality` (Phase 4b).
  → **Full-Table-Scan, kein Spatial-Index.**

### 1.5 Externe Services (backend/internal/services/)

- `labelloc.go` — `https://labelloc.example.org/api/location?lat=…&lon=…&lang=de`
  - Cache-Key: `CoordinateKey(lat, lon, lang)` SHA-256 mit 5-Decimal.
  - `repairDoubleEncodedUTF8()` korrigiert Mojibake.
  - Result: `LabellocResult{Country, CountryISO, AdminArea,
    AdminArea2, AdminArea3, Locality, LocationDescription}`.
- `mtb.go` — `https://coordstomtb.example.org/api/coordinate?lat=…&lon=…`
  - Result: `MTBResult{SheetNumber, SheetName, Quadrant, Found,
    SheetBoundaries}`. Außerhalb DE: `Found=false`, kein Error.
- `geocache.go` — Get/Put mit TTL-Check (default 7d). Unique-Index
  `(service, key)` macht Kollisionen unmöglich.

### 1.6 API (backend/internal/api/)

- `RegisterLabelRoutes` — `POST /api/label-pdfs/locality`,
  `POST /api/label-pdfs/determination`. Auth: `RequireRecordAuth("users")`.
- `RegisterExportRoute` — `GET /api/export` (ZIP-Backup, kein Re-Import-Format).

### 1.7 Codes & Grouping (DB-frei, testbar)

- `codes/codes.go`: `CollectingDay(ts, cutoffHour)`,
  `FormatCode(day, seq)` → `YYMMDD/N`, `ParseSequence(code)`.
- `grouping/grouping.go`: `FindOrCreate(repo, ownerID, day, ts)`,
  `ExpandWindow(excursion, ts)`, `SpansMidnight(...)`. Repo via
  Interface → in `hooks/sample_create.go` mit `daos.Dao` implementiert.

### 1.8 Sync-Felder (Status quo)

| Collection | client_uuid | client_updated_at | version |
|---|---|---|---|
| samples | ✓ | ✓ | – |
| excursions | ✓ | ✓ | – |
| determinations | ✓ | – | – |
| sample_photos | ✓ | ✓ | – |
| localities | – | – | – |
| placemarks | (n/a, Collection existiert nicht) | | |

Kein `version`-Feld auf irgendeiner Collection.

---

## 2. iOS-Client

### 2.1 Stack

- iOS 17.0+ (project.yml:17), SwiftUI-only (UIKit nur in
  `MapSnapshotter` für UIImage-Rendering).
- Persistenz: **GRDB 6.29.0+** (kein SwiftData/CoreData).
- Tests: `SnapshotTesting 1.17.0+`.
- Drei Build-Configs (Debug/Staging/Release).
- Logging: `Core/Observability/Log.swift:8` — OSLog, Subsystem
  `org.fieldworksdiary`, Categories: App, Auth, Sync, Persistence,
  Network, Location, UI, Metrics.

### 2.2 Domain-Modelle (Decodable Structs, Wire-Format)

| Modell | Datei:Line | Felder |
|---|---|---|
| `Sample` | Core/Models/Sample.swift:27 | `id`, `code`, `originalCode`, `excursion`, `lat`, `lon`, `accuracyM`, `altitudeM`, `collectedFrom`, `notes`, `marked`, `clientUuid`, `clientUpdatedAt`, `adminUnits` (nested), `mtb` (nested) |
| `Locality` | Core/Models/Locality.swift:5 | `id`, `name`, `centroidLat`, `centroidLon`, `radiusM`, `notes` (0-Werte → nil) |
| `Excursion` | Core/Models/Excursion.swift:30 | `id`, `name`, `collectingDay`, `nightExcursion`, `startedAt`, `endedAt`, `centroidLat`, `centroidLon`, `adminUnits`, `mtb`, `astro`, `locality`, `suggestedLocality`, `dayOfYear`, `country`, `adminArea`, `permitNumber`, `permitPDFFile` |
| `Person` | Core/Models/Person.swift:3 | `id`, `fullName`, `abbreviation`, `email`, `notes` |
| `Determination` | Core/Models/Determination.swift:35 | `id`, `sample`, `speciesText`, `kind` (DeterminationKind: det/t/vid), `person`, `determinedOn`, `notes` |

Es gibt keinen `LocationSource`-Enum-Typ und kein `Placemark`-Modell.

### 2.3 Lokale GRDB-Records (Persistence-Layer, getrennt von Wire-DTOs)

- `LocalSample` (Core/Persistence/LocalSample.swift:11) —
  `FetchableRecord`, `MutablePersistableRecord`. Felder: lat/lon/accuracy/altitude
  als separate Spalten, `collectedFrom` Date, `syncStatus`
  (pending/syncing/synced/failed), `syncError`, `backendId`, `userId`,
  `createdAt`, `updatedAt`.
- `LocalExcursion` (Core/Persistence/LocalExcursion.swift:8) —
  `adminUnitsJson`, `mtbJson`, `astroJson` als String-Blobs.
- `LocalLocality` (Core/Persistence/LocalLocality.swift:4) — direkte
  Spalten, kein JSON.

CLLocation wird also **als Komponenten** gespeichert (lat/lon/alt/hAcc) —
spec-konform.

### 2.4 Sync zu PocketBase

- **REST-basiert** (kein WebSocket / kein Realtime-Subscription).
- `SyncRunner` (Core/Sync/SyncRunner.swift:48):
  - 30-Sekunden-Retry-Loop für `.pending`/`.failed` Samples (Z. 102–114).
  - `kick()` triggert On-Demand-Pass (Z. 94).
  - Enrichment-Polling (Z. 253–270): 1.5 s Intervall, max 6 Versuche.
  - `client_uuid` + `client_updated_at` im `SampleCreateInput`
    (Z. 16–17) für Idempotenz.
- Pro-Collection-Clients in `Core/PocketBaseClient/`:
  - `SampleClient`, `LocalityClient`, `ExcursionClient`, `PersonClient`,
    `DeterminationClient`, `PhotoClient` (multipart).
- **Keine explizite Outbox-Tabelle** wie `pending_mutations` —
  `syncStatus` lebt direkt auf den `Local*`-Records.

### 2.5 LocationProvider

- `Core/Location/LocationProvider.swift:7` — `LocationProvider.Status` Enum:
  `idle, requestingAuthorization, denied, locating, fixed(CLLocation),
  failed(String)`.
- Wird in `CoordinatePickerView` benutzt; ist kein
  Persistenz-Konzept.

### 2.6 Design-System (Core/Theme/)

Komplettes Token-Set vorhanden: `AppColor`, `AppFont`, `AppSpacing`,
`AppRadius`, `AppShadow`, `AppMotion`, `AppMetric` (deprecated),
`AppZIndex`. Regeln in `.claude/rules/DESIGN-SYSTEM.md`.

### 2.7 Features-Folders

```
ios/Fieldworksdiary/Features/
├── AddSample/
├── Auth/
├── Calendar/
├── Debug/
├── Excursions/
├── Health/
├── Home/
├── Localities/
├── Photos/
├── SampleEditor/
├── Samples/
└── Settings/
```

### 2.8 Auth-Status

Apple-Sign-In + Email/Password (siehe `docs/APPLE_SIGN_IN_SETUP.md`,
Migration `1700000010_phase11a_users_extended.go`).

---

## 3. Daten-Inventur

- **Aktive PB-Daten lokal:** `backend/pb_data/` existiert
  (`backend/pb_data` Verzeichnis, Inhalt nicht ausgewertet — wird in der
  späteren Migration-Phase betrachtet).
- **Aktuelle Phase laut PHASES.md:** Phase 14 in progress (UI-Redesign
  Home + Sample-Foto, gestartet 2026-05-20). Phasen 0–11 + 10 done.
  Phase 9 (FloraIncognita) und Phase 12/13 (Tile-Caching, Hardening)
  pending. Keine harten Produktiv-Daten-Volumen-Zahlen erhoben — gehört
  in Phase 9 (Migration) der Refactoring-Spec.

---

## 4. Konventionen, die zwingend beachtet werden

Aus `.claude/rules/` und `CLAUDE.md`:

- **Englische Bezeichner im Code**, deutsche Strings in der UI.
- **Conventional Commits**, lokal erzwungen über
  `.githooks/commit-msg`.
- **Logging-Konvention** (`.claude/rules/LOGGING.md`) — strukturiertes
  `slog` im Backend, `Log.<category>` aus OSLog auf iOS, keine PII /
  vollen Koordinaten im Klartext.
- **Design-System & Accessibility** (`.claude/rules/DESIGN-SYSTEM.md`,
  `.claude/rules/ACCESSIBILITY-IOS.md`) — Tokens-only in Features,
  44 × 44 pt Tap-Targets, AX5-fähig.
- **PocketBase als Library**, nie als Standalone-Binary.
- **Phasen-Disziplin:** PHASES.md ist Single Source of Truth, kein
  Überspringen.

---

## 5. Externe Referenzen

- `PROJECT_PLAN.md` §10 (geplantes Layout), §11 (Phasen).
- `PHASES.md` — aktiver Status.
- `docs/openapi.yaml` — aktuelles API-Schema.
- `docs/adr/` — Architecture-Decision-Records.
- `docs/ENVIRONMENTS.md` — Dev/Staging/Prod-Setup.
