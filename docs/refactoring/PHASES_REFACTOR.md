# PHASES_REFACTOR.md — Refactoring-Initiative "Sample / Locality / Placemark"

Stand: 2026-05-26 · Aktive Quelle: `fieldsampling-refactoring-plan.md`
(Spec), `inventory.md` (Ist), `gap-analysis.md` (Soll-Diff).

Diese Datei ist die **Single Source of Truth für den Phasen-Status des
Refactorings**. Sie läuft parallel zu `PHASES.md` (Feature-Phasen
0–14), kollidiert aber inhaltlich mit den dort offenen Phasen 12 und
13 — siehe §Konflikte unten.

Konvention: bei jedem Statuswechsel **erst hier eintragen**, dann
weiterarbeiten — analog zur `PHASES.md`-Regel in `CLAUDE.md`.

Status-Legende: `pending` · `in progress` · `done` · `blocked`.

---

## Aktive Phase

**R7.1 + R7.2 done** (2026-05-27, Branch
`refactor/R7-placemark-pipeline`). Reverse-Geocoding läuft jetzt
backend-seitig auf Locality-Events; manuelle Korrekturen sind
über zwei Custom-Endpoints möglich.

R7.1 (Auto-Geocode-Hook):
- `internal/enrichment/placemark.go` — Hook auf Locality-Create +
  Update (re-fire bei Koord-Shift > 100 m ODER fehlendem
  Placemark). Labelloc-Lookup (reuse bestehender Client + Cache),
  Dedup-Hash (NFC + lower + `|`-join + SHA-256), `placemarks`-
  Lookup-or-create, `locality.placemark` setzen.
- Manual-Override sakrosankt: `geocoding_source == "manual"` →
  no-op.
- Async + recover. Labelloc-Ausfall blockiert nie den
  Locality-Save; nächste Koord-Update-Tick fires den Hook
  erneut.
- 10 Tests: 6 Hash-Properties + 4 Hook-Integration
  (lookup-or-create on first run, shared Placemark across
  Localities, manual override respected, no-coords no-op).

R7.2 (Manual-Override-Endpoints):
- `internal/api/placemark.go` — zwei Custom-Routes, beide
  owner-scoped:
  - `PATCH /api/localities/:id/placemark` — Body: country
    (ISO-2 required), administrative_area, sub_administrative_area,
    locality, sub_locality, postal_code, name, thoroughfare.
    Lookup-or-create mit `geocoding_source = manual`, locality
    re-pointen.
  - `DELETE /api/localities/:id/placemark/override` — Locality
    detacht. Placemark-Row bleibt (andere Localities könnten
    referenzieren). Nächster Auto-Geocode füllt neu.
- 6 Tests: happy-path, missing country (400), foreign locality
  (403), no auth (401), clear-detaches, hash-lock-test gegen
  Drift zwischen api- und enrichment-Implementierung.

Wiring (`main.go`): `RegisterPlacemarkEnricher` läuft im
`OnBeforeServe`-Hook neben `Enricher.Register()`,
`RegisterPlacemarkOverrideRoutes` daneben.

**Was NICHT in R7.1/R7.2 ist:**
- **R7.3** — Backfill bestehender `samples.admin_units`-JSON-
  Snapshots in `placemarks`. Datenmigration, eigener PR.
- **R7.4** — `samples.admin_units` droppen. Erst nach R7.3 +
  einer Woche Beobachtung in Staging (Spec §6.1).
- **iOS-Anzeige des Placemark** — UI-Arbeit, gehört zu R8.

R6 abgeschlossen (R6.1 Server-Fusion + R6.2 iOS-Remap +
R6.3 Offline-Algorithmus). R7 zur Hälfte (R7.1+R7.2 done;
R7.3+R7.4 als Folge-PR).

Nächste Phase: **R8** (UI-Refactor, inkl. AddSample-Sheet,
Placemark-Anzeige in Locality-Detail, Fusion-Toast,
FlagAmbiguous-Badge, Manual-Override-UI) oder **R7.3/R7.4**
(Backfill + Drop alter Spalten). R8 ist umfangreicher.

R6.3 liefert:

- **`Core/Geo/LocalityFusion.swift`** — Namespaced enum mit
  `Candidate{id,latitude,longitude}` und `offlineFuseLocality(
  sampleLat, sampleLon, candidates, radius=50, excludingID)`.
  Pure-Swift, file-private Haversine, keine Abhängigkeiten zum
  Persistence- oder Wire-Layer. Plattform-identisch zu dem,
  was Android/Web später implementieren — kein Drift-Risiko.
- **6 Unit-Tests** (`LocalityFusionTests`): 30 m east attach,
  200 m east kein Match, leere Liste kein Match, ~49 m
  Boundary attach (floating-point-stabil), zwei Kandidaten →
  Nearest gewinnt, `excludingID` skipt Self.

**Was NICHT in R6.3 ist:** Die Integration des Algorithmus in
den AddSample-Flow ist eigene Arbeit. Sie zieht:
- ein `LocalityClient`-Update auf Spec-aligned Field-Namen
  (heute noch `centroid_lat`/`centroid_lon`/`radius_m`),
- eine Outbox-Mutation `.locality/.create` plus
  SyncRunner-Dispatch dafür,
- UI-Strings + sehr leichte Sheet-Logik für „neue Locality?"
  vs. „bestehende übernehmen".

Diese Integration gehört zu R8 (UI-Refactor) oder einem
dedizierten R6.4. R6 (Locality-Fusion) ist mit R6.1/R6.2/R6.3
in seinem Phase-5-Scope (Spec §5.1/5.2/5.3) komplett — der
Algorithmus-Pfad ist Server-und Client-seitig live, der
Remap-Event-Pull funktioniert, der Offline-Algorithmus ist
verfügbar und getestet.

Nächste Phase: **R7** (Placemark-Pipeline / Reverse-Geocoding-
Hook + Manual-Override-Endpoint, Spec §6) oder **R8**
(UI-Refactor, inkl. Fusion-Integration im AddSample-Flow,
Remap-Toast, FlagAmbiguous-Badge). Reihenfolge offen — R7
braucht weder Fusion-UI noch Outbox-Erweiterungen.

R6.2 liefert:

- **`Core/Models/LocalityRemapEvent.swift`** — Decodable mit
  owner/oldLocalityID/newLocalityID/reason
  (mergedWithExisting|duplicateCleanup)/affectedSampleIds.
  Toleriert PocketBase-JSON-Wrap und direkten Array-Shape.
- **`Core/PocketBaseClient/RemapEventClient.swift`** —
  `listSince(Date?)` mit `filter=created > "ISO"`,
  `sort=created` (oldest first → apply in order).
- **`LocalLocalityStore.applyRemap(oldID, newID)`** — single
  GRDB-Transaction: `UPDATE local_samples` re-pointen +
  `DELETE local_localities`. Idempotent (zweiter Lauf ist
  No-op). Self-Merge → No-op (defensive).
- **`Core/Sync/RemapEventsPuller.swift`** — Single-flight
  Hydrator analog zu den anderen. Cursor in UserDefaults pro
  User-ID, advance per Event (mid-batch-Crash replay'd nicht
  die ganze Queue). Postet `Notification.localityRemapApplied`
  mit `movedCount` userInfo.
- **AppContainer-Wiring** — `remapPuller` neben den anderen
  Hydratoren, in `hydrateAll()` parallel. `wipeLocalStores()`
  resettet Cursor beim User-Switch.

Tests:
- `LocalLocalityStoreRemapTests` (4 Cases): re-point + delete,
  idempotency, unknown-old no-op, self-merge no-op. Alle
  Logik-Tests grün.

R6.1 + R6.2 komplett. Nächste Phase: **R6.3** (Client-Side
Offline-Fusion im AddSample-Flow, Spec §5.1).

R6.1 liefert:

1. **`internal/fusion/`** — Pure-Go-Algorithmus.
   `ServerFuse(incoming, candidates, Settings)` mit adaptivem
   Radius `max(50, 2*hAcc_incoming, 2*max(hAcc_candidates))`,
   Self-Exclude, Haversine-Distance (`grouping.HaversineMeters`).
   9 Unit-Tests inkl. zero/one/many-Candidates, hohe Accuracy
   beider Seiten, Custom-MinRadius, `SignificantCoordChange`.
2. **Migration 1700000019** — `localities.needs_human_review`
   (Bool, default false) + Collection
   `locality_remap_events` (owner-scoped read, write nil).
3. **`internal/hooks/locality_fusion.go`** —
   `RegisterLocalityFusion(app, fusion.Settings{})`. Triggert
   auf `OnRecordAfterCreate/UpdateRequest("localities")`,
   Update nur bei Koord-Shift > 100 m
   (`fusion.SignificantCoordChange`). MergeInto-Pfad re-pointed
   Samples in einer Transaction, emittiert
   `locality_remap_events`-Row, löscht die Duplikat-Locality.
   FlagAmbiguous setzt `needs_human_review=true`. KeepAsIs
   clearet einen stale Flag.
4. **Integration-Tests** — 5 Tests gegen die TestApp: KeepAsIs,
   Merge+Event-Emit (mit Sample-Re-Pointing), FlagAmbiguous,
   Owner-Scope (Alice-Locality unsichtbar für Bobs Fusion),
   Notes-Only-Edit triggert nicht.

`go test ./...` durchgehend grün. Test-Fixtures aus Spec §5.5
(Kreuzwertheim/Wertheim mit konkreten Koord-Sätzen) sind in
diesem Inkrement nicht enthalten — die Algorithmus-Properties
sind über die synthetischen Tests abgedeckt, die Fixtures
liefere ich nach sobald die Datensätze im Repo sind.

Nächste Phase: **R6.2** (iOS RemapEventsPuller +
`LocalitiesStore.applyRemap`) oder **R6.3** (Client
Offline-Fusion). Beide unabhängig — Reihenfolge offen.

---

## Bestätigte Designentscheidungen (aus R1)

Aus `gap-analysis.md` §11 vom User in der Phase-1-Abnahme akzeptiert.
Hier nur die *Antworten*, ohne Begründung:

| Punkt | Entscheidung |
|---|---|
| 1.1 Sample.notes | optional, UI normalisiert leer → `nil` |
| 1.2 Sample.location | optional am Modell, required am Use-Case |
| 1.3 Locality.notes/location | location required, notes optional |
| 1.4 Placemark-Felder | gemäß Spec-Tabelle; Hash NFC+lowercased+`\|`-join im Backend |
| 1.5 Sample.version | behalten + zusätzlich `client_updated_at` |
| 1.6 Sample.fieldtrip | required |
| 1.7 Sample.locality | **required** (Spec) — impliziert Bestands-Backfill |
| NEW-1 Naming | Excursion → Fieldtrip, UI-Strings „Exkursion" bleiben |
| NEW-2 Fieldtrip-Felder | `mtb`/`astro`/`day_of_year`/`country`/`admin_area`/`permit_*` behalten; `admin_units` wandert mittelfristig, bleibt aber als Snapshot |
| NEW-3 Locality.radius_m | behalten als „beobachtete Streuung" |
| NEW-4 Locality.name | behalten, optional |
| NEW-5 geocache vs placemarks | beide behalten (verschiedene Layer) |
| NEW-6 Backfill | Migrations-Skript erzeugt 1:1-Localities, danach Server-Fusion |
| NEW-7 OpenAPI | wird in jeder Schema-Phase synchron aktualisiert |
| NEW-8 Realtime | offen — ADR vor Phase R5 |
| NEW-9 Plan-Doc | diese Datei, koexistierend mit `PHASES.md` |

User-Modifikationen am Ist-Stand in `gap-analysis.md`:
- `beginDate`/`endDate` sind **DateTime-Typ**, nicht reine Date.
- `sample_id` ist **unique pro owner**, nicht projektweit non-unique
  und nicht global-unique.

---

## Konflikte mit `PHASES.md`

Die laufende Feature-Phase 14 berührt UI-Redesign (Home, Sample-Foto)
und damit `Features/AddSample/`, `Features/Home/`, `Features/Samples/`.
Phase R8 (UI-Anpassungen) trifft die gleichen Folder. Empfehlung:

- R2–R7 laufen, bevor Phase 14 noch unzulässig viel UI-Geometrie
  einzementiert. UI-Anpassungen aus Spec §7 werden dann in R8
  konsolidiert.
- Phase 12 (Production-Härtung) und Phase 13 (Tile-Caching) bleiben
  in `PHASES.md` parallel pending und werden nicht durch das
  Refactoring blockiert.

---

## Phasenübersicht

| Phase | Titel | Status | Blockiert von | Abhängig in |
|---|---|---|---|---|
| R0 | Inventur | done | – | – |
| R1 | Designfragen / Decisions | done | R0 | – |
| R2 | Rename Excursion → Fieldtrip | done | R1 | alle folgenden |
| R3 | PB-Schema-Erweiterungen | done | R2 | R4, R5, R6, R7 |
| R4 | iOS-Modelle synchron | done | R3 | R5, R6, R8 |
| R5 | Sync: Outbox-Infrastruktur + Version-Conflict + ADR | done | R3, R4 | R6 |
| R5b | SyncRunner ↔ Outbox-Verdrahtung | done | R5 | – |
| R6.1 | Locality-Fusion Server-Side | done | R5 | – |
| R6.2 | iOS RemapEventsPuller + applyRemap | done | R6.1 | – |
| R6.3 | iOS Offline-Fusion (Algorithmus + Tests) | done | R6.1 | R8 |
| R7.1 | Backend Placemark-Auto-Geocode-Hook | done | R3 | – |
| R7.2 | Backend Manual-Override-Endpoints | done | R3 | – |
| R7.3 | Backfill admin_units → Placemarks | pending | R7.1 | R7.4 |
| R7.4 | Drop samples.admin_units | pending | R7.3 | – |
| R8 | UI-Anpassungen | pending | R4, R6, R7 | – |
| R9 | Export (GPX/CSV/JSON) | pending | R7 | – |
| R10 | Daten-Migration Bestand | pending | R5, R6, R7 | – |
| R11 | Planning-Feature (`planned_locality`) | pending | R7 | – |

Jede Phase = mindestens ein PR, jeder PR strikt einzeln gemerged.
Wo PR-Split angedeutet ist, sind die Commits unten konkret aufgelistet.

---

## R0 — Inventur

**Status: done** (2026-05-22).

Artefakte:
- `docs/refactoring/inventory.md`
- `docs/refactoring/gap-analysis.md`

---

## R1 — Designfragen

**Status: done** (2026-05-26).

User-Abnahme via Lesen + zwei punktuelle Edits in `gap-analysis.md`.
Entscheidungen oben unter "Bestätigte Designentscheidungen".

Offen: ADR zu NEW-8 (Realtime vs aggressive Polling) — vor R5 als
eigene Akte. **Nicht R5-blockierend**, weil R5 die `version`-Spalte
und Outbox auch ohne Realtime einführen kann.

---

## R2 — Querschnitts-Rename: Excursion → Fieldtrip

**Status: done** (2026-05-26). Ziel: jeder Code-Identifier `Excursion`/
`excursion`/`excursions` wird zu `Fieldtrip`/`fieldtrip`/`fieldtrips`.
**UI-Strings auf Deutsch („Exkursion") bleiben unverändert.**

### Akzeptanzkriterium

- `go test ./...` grün.
- `xcodebuild ... build` grün.
- `grep -nri 'excursion'` im Code (außerhalb von UI-String-Catalogs
  und `docs/refactoring/`) liefert **null** Treffer.
- Bestands-Records in `pb_data/` sind unter `fieldtrips`-Collection
  erreichbar, `samples.fieldtrip` zeigt korrekt auf den Trip.
- Eine neue Migration `1700000014_phase14c_rename_excursion_to_fieldtrip.go`
  ist gelaufen und idempotent.

### PR-Struktur (ein PR, drei Commits)

**Commit 1 — Backend-Rename + Daten-Migration**

1. Neue Migration `backend/migrations/1700000014_phase14c_rename_excursion_to_fieldtrip.go`:
   - `UpdateCollection({Name: "fieldtrips"})` auf Collection-ID-Basis
     (Collection-IDs sind stabil, Relations bleiben intakt).
   - Field-Rename auf `samples`: `excursion → fieldtrip`.
   - Index-Renames: `idx_excursions_*` → `idx_fieldtrips_*`,
     `idx_samples_excursion → idx_samples_fieldtrip`.
   - Idempotent: rename überspringen, wenn `fieldtrips` schon
     existiert.
2. Code-Renames (mechanisch):
   - `backend/internal/grouping/grouping.go`: `type Excursion struct →
     Fieldtrip`, alle Methoden.
   - `backend/internal/enrichment/excursion.go → fieldtrip.go`:
     Funktion `recomputeExcursionDerived → recomputeFieldtripDerived`,
     DAO-Queries `FindRecordById("excursions", …) →
     FindRecordById("fieldtrips", …)`.
   - `backend/internal/hooks/sample_create.go`: `pbRepo`-Methoden
     (`FindByUserAndDay`, `excursionFromRecord`, `writeExcursion`,
     `rec.Set("excursion", …)`).
   - `backend/internal/astro/astro.go`: `ExcursionAstro →
     FieldtripAstro`, `ComputeExcursionAstro → ComputeFieldtripAstro`.
   - `backend/internal/api/export.go`: `pdfs/excursions/{id} →
     pdfs/fieldtrips/{id}`, Filter-Queries.
   - `backend/internal/api/labels.go`: `batchLoadExcursions →
     batchLoadFieldtrips`, FK-Lookups.
3. Tests: alle `*_test.go` Helper (`makeExcursion`, `TestProcessSample_*`,
   `TestExcursionFromRecord_*`) umbenennen.
4. `go test ./...` muss grün sein, bevor Commit gepusht wird.

**Commit 2 — iOS-Rename**

1. Folder-Rename: `ios/Fieldworksdiary/Features/Excursions/ →
   Features/Fieldtrips/`. Dateien innerhalb umbenennen
   (`ExcursionDetailView → FieldtripDetailView`, etc.).
2. Modell-Renames:
   - `Core/Models/Excursion.swift → Fieldtrip.swift` (`struct Excursion
     → Fieldtrip`, nested `Astro` mit `moonAboveHorizonDuringExcursion
     → moonAboveHorizonDuringFieldtrip`).
   - `Core/Persistence/LocalExcursion.swift → LocalFieldtrip.swift`
     mit GRDB-Schema-Migration: bestehende SQLite-Tabelle wird per
     GRDB-Migration umbenannt.
   - `Core/Persistence/LocalExcursionStore.swift → LocalFieldtripStore.swift`.
3. `Core/PocketBaseClient/ExcursionClient.swift → FieldtripClient.swift`.
   API-Pfade umstellen auf `/api/collections/fieldtrips/records`.
4. `Core/Sync/ExcursionsHydrator.swift → FieldtripsHydrator.swift`.
5. `AppContainer.swift`: Property `excursions → fieldtrips`.
6. `HomeViewModel.swift`: `ActiveExcursion → ActiveFieldtrip`,
   `activeExcursion → activeFieldtrip`.
7. `xcodebuild ... build` grün, bevor Commit gepusht wird.

**Commit 3 — Docs / OpenAPI / project.yml**

1. `docs/openapi.yaml`: Schema-Pfade und Beispiele.
2. `PROJECT_PLAN.md`: Code-Identifier-Referenzen — UI-Strings
   („Sammeltag", „Exkursion") **explizit nicht** anfassen.
3. `PHASES.md`: nur dort, wo „Excursion" als Code-Konzept benannt
   wird, nicht in den Deutsch-formulierten Phasen-Titeln.
4. Kein Update auf `ios/project.yml`, `docker-compose*.yml`, `cliff.toml`
   nötig (laut Inventur null Treffer).

### Tests

- `go test ./...` und `go test ./internal/codes -run TestCollectingDay`
  (Smoke).
- iOS: bestehende Unit-Tests müssen ohne Anpassungen außer Imports
  grün laufen.
- Manueller Smoke: `docker compose up --build`, dann `curl
  http://localhost:8090/api/collections/fieldtrips/records` →
  200 + Bestandsdaten.

### Risiken

- **GRDB-Tabellen-Rename auf iOS**: bestehende lokale DBs auf Geräten
  müssen migriert werden. GRDB-Migration mit `database.alter` und
  `RenameTable`. Vorhandene `migrationCount`-Schema bumpen.
- **Bestandsdaten in `pb_data/`**: bei Collection-ID-stabilem
  `UpdateCollection({Name:"fieldtrips"})` bleiben Records intakt.
  Vorher `pb_data/` snappen (`docs/DISASTER_RECOVERY.md`).
- **Doppel-Run der Migration**: idempotent prüfen, sonst rename auf
  bereits umbenannte Collection läuft auf Fehler.

---

## R3 — PocketBase-Schema-Erweiterungen

**Status: pending.** Ziel: alle neuen Spalten und die Placemark-
Collection sind im Schema, aber **noch ohne** Sync-Logik / Hook-
Konsequenzen. Nur Schema + Defaults.

### PR-Struktur (vier Migrationen, ein PR pro Collection-Gruppe)

**R3.1 — `placemarks` Collection (eigener PR)**

Migration `1700000015_phase_R3_placemarks_collection.go`:
- Felder: `country` (Text required, max 2), `administrative_area`,
  `sub_administrative_area`, `locality`, `sub_locality`, `postal_code`,
  `name`, `thoroughfare` (alle Text optional),
  `geocoding_source` (Select required: `backend-service`, `manual`),
  `geocoding_service_version` (Text), `geocoding_date` (Date),
  `dedup_hash` (Text required, unique-index).
- Index: `idx_placemarks_dedup_hash` unique.
- Rules: list/view = owner-scoped wenn `owner` ergänzt wird;
  alternativ admin-only (read-through über Locality). **Entscheiden in
  R3.1**: hat Placemark einen `owner`? Empfehlung: nein, weil
  Placemarks sich zwischen Localities teilen — sie sind eine
  Reference-Table.

Akzeptanzkriterium: `docker compose up --build` läuft, Admin-UI zeigt
`placemarks` mit 0 Records.

**R3.2 — `localities` Erweiterung**

Migration `1700000016_phase_R3_localities_extended.go`:
- Adds: `latitude` (Number), `longitude` (Number), `altitude`
  (Number), `horizontal_accuracy` (Number), `vertical_accuracy`
  (Number), `location_source` (Select required: `user`,
  `location_service`, `sample`, `locality`), `location_number` (Text),
  `placemark` (Relation → `placemarks`, single, optional),
  `version` (Number default 1), `client_uuid` (Text), `client_updated_at`
  (Date).
- Daten-Migration: `centroid_lat → latitude`, `centroid_lon →
  longitude` (kopieren). `centroid_lat`/`centroid_lon` **noch nicht
  droppen** — erst nach R8/R10, wenn UI umgestellt ist.
- Backfill `location_source`: GPS-Genauigkeit aus erstem Sample
  ablesen → `location_service`, sonst → `user`.
- Index: `idx_localities_lat_lon` (composite, non-unique) für Fusion-
  Queries.

**R3.3 — `samples` Erweiterung + Renames**

Migration `1700000017_phase_R3_samples_extended.go`:
- Adds: `is_all_day` (Bool default false), `time_zone` (Text default
  `Europe/Berlin`), `version` (Number default 1, required),
  `location_source` (Select required), `vertical_accuracy` (Number),
  `locality` (Relation → `localities`, optional zunächst, später
  required nach Backfill).
- Renames: `code → sample_id`, `collected_from → begin_date`,
  `collected_to → end_date`, `lat → latitude`, `lon → longitude`,
  `accuracy_m → horizontal_accuracy`, `altitude_m → altitude`.
- Optional-Schaltung: `latitude`/`longitude` werden von required auf
  optional gesetzt (Designentscheidung 1.2).
- `sample_id` Index: alter Index löschen, neuer **composite unique
  index `(owner, sample_id)`** anlegen (User-Modifikation in
  Gap-Analyse).
- `begin_date`/`end_date` Typ-Confirmation: PocketBase
  Date-Field-Type ist DateTime — explizit dokumentieren.

**R3.4 — `fieldtrips` Anreicherung**

Migration `1700000018_phase_R3_fieldtrips_extended.go`:
- Adds: `notes` (Editor optional), `version` (Number default 1).
- Renames: `name → title`, `started_at → begin_date`, `ended_at →
  end_date`.
- Felder gemäß NEW-2 *bleiben stehen*: `admin_units`, `mtb`, `astro`,
  `permit_*`, `day_of_year`, `country`, `admin_area`,
  `centroid_lat/lon`.

### Akzeptanzkriterium für R3 gesamt

- Vier Migrationen laufen idempotent durch.
- `docker compose up --build` startet PocketBase ohne Fehler.
- Admin-UI zeigt alle neuen Felder, Defaults greifen.
- Backend-Tests `go test ./...` grün (Hook-Logik ist *noch nicht*
  umgestellt — die nutzt weiter `excursion` als Variablen-Name, weil
  der Rename in R2 schon passiert ist; aber die *Feldnamen* in den
  PocketBase-Rec-Calls sind neu — siehe R5).
- OpenAPI-Spec `docs/openapi.yaml` ist synchron aktualisiert
  (NEW-7).

### Risiken

- Field-Rename in PocketBase erhält Daten, aber ältere Clients lesen
  fehl. **R4 (iOS-Modelle) muss zeitnah folgen**.
- `samples.locality` ist initial optional — der Hook muss in R5
  auf required gehoben werden, sobald iOS sendet.

---

## R4 — iOS-Modelle synchron

**Status: pending.** Setzt R3 voraus. Ziel: Wire-DTOs, lokale
GRDB-Records und Domain-Modelle im Client decken das neue Schema
ab.

### PR-Struktur (ein PR)

1. `Core/Models/LocationSource.swift` neu — Enum mit Int-RawValue und
   String-Codable für PB.
2. `Core/Models/Placemark.swift` neu — Decodable mit allen Spec-1.4-
   Feldern; lokales GRDB-Pendant `Core/Persistence/LocalPlacemark.swift`.
3. `Core/Models/Sample.swift`: Property-Renames (`code → sampleID`,
   `collectedFrom → beginDate`, `collectedTo → endDate`, `lat →
   latitude`, `lon → longitude`, `accuracyM → horizontalAccuracy`,
   `altitudeM → altitude`); neue Felder
   (`verticalAccuracy`, `version`, `isAllDay`, `timeZone`,
   `locationSource`, `locality`).
4. `Core/Models/Locality.swift`: neue Felder analog.
5. `Core/Models/Fieldtrip.swift`: `name → title`, `startedAt →
   beginDate`, `endedAt → endDate`, `notes`, `version`.
6. `Core/Persistence/Local*.swift` + GRDB-Migrations für neue Spalten.
7. Mapping-Layer in `Core/Persistence/Mappers/` (oder bestehender
   Ort): Wire ↔ Local ↔ Domain.
8. `Core/Sync/*Client.swift` Anpassungen für neue Feldnamen.

### Akzeptanzkriterium

- `xcodebuild` grün.
- Bestehende Unit-Tests in `FieldworksdiaryTests` grün; neue Tests
  für LocationSource-Roundtrip (Int ↔ String), Date/Timezone-Roundtrip
  mit IANA-Identifier (Spec §9).
- AddSample-Flow im Simulator legt ein Sample mit `locationSource =
  .locationService` an, das Sample ist in PB sichtbar.

### Risiken

- GRDB-Migration auf User-Geräten: bestehende DBs werden zur Laufzeit
  mit Spalten-Adds migriert. Migration mit `database.alter` in
  GRDB-DatabaseMigrator anhängen, **migrationCount bumpen**.
- `Sample.locality` zunächst optional auf iOS-Seite — wird in R6
  mit Offline-Fusion automatisch gesetzt.

---

## R5 — Sync: Outbox + Version + Realtime-ADR

**Status: pending.** Setzt R3+R4 voraus.

### PR-Struktur

**R5.0 — ADR `0004-realtime-vs-polling.md`** (eigener Doc-PR, nicht
blockierend für R5.1/R5.2)
- Option A: WebSocket gegen PocketBase Realtime
- Option B: REST-Polling mit Conditional Requests
- Empfehlung mit Begründung, Konsequenzen für Battery / Bandwidth
- User-Approval erforderlich, bevor Realtime-Code geschrieben wird

**R5.1 — Version-Feld in Push/Pull integrieren**

1. Backend: Hook `OnRecordBeforeUpdate` prüft `incoming.version`
   gegen `current.version`; bei `incoming.version <= current.version`
   → `409 Conflict`. Hook erhöht `version` beim Server-Write auf
   `current.version + 1`.
2. iOS: `SyncRunner` inkrementiert `version` vor jedem Push. Bei 409
   → Pull-Refresh und Konfliktauflösung. `notes`-Konflikt: User-Sheet
   („Server / lokal / merge").

**R5.2 — Outbox-Tabelle**

1. iOS: neue GRDB-Tabelle `pending_mutations`:
   - `id` (PK), `entity_type` (Text), `entity_id` (Text optional bei
     create), `op` (`create|update|delete`), `payload_json` (Blob),
     `created_at`, `attempts`, `last_attempt_at`, `last_error`.
2. `SyncRunner` schreibt Mutations dort hin, statt nur `syncStatus`
   auf `Local*` zu setzen.
3. Abarbeitungs-Reihenfolge:
   `Placemark → Locality → Fieldtrip → Sample → SamplePhoto →
   Determination` (FK-Reihenfolge gemäß Spec §4.2).
4. Migration der bestehenden `.pending`/`.failed`-Local*-Records →
   `pending_mutations` (einmalige App-Boot-Migration).

**R5.3 — Realtime / Polling (gemäß ADR)**

Wird ausformuliert sobald ADR steht.

### Akzeptanzkriterium

- Server lehnt versionierte Konflikte mit 409 ab; iOS löst korrekt
  auf.
- Outbox überlebt App-Kill ohne Datenverlust (Test: AddSample im
  Flugmodus → App killen → wieder starten → online → Sample
  synchronisiert).
- Notes-Konflikt erzeugt User-Sheet, keine stille Datenverluste.

### Risiken

- Backward-Compat: Server-Hooks dürfen alte Clients ohne `version`-
  Feld nicht hart ablehnen. Initial-Window: fehlendes `version` =
  `0`, akzeptieren, danach inkrementieren. Cutoff-Datum dokumentieren.

---

## R6 — Locality-Fusion (Server-first)

**Status: pending.** Setzt R5 voraus.

### PR-Struktur (drei PRs)

**R6.1 — Server-Fusion + Tests**

1. Migration `1700000019_phase_R6_locality_fusion.go`:
   - `localities.needs_human_review` (Bool default false).
   - Neue Collection `locality_remap_events`:
     - `old_locality_id`, `new_locality_id`, `reason` (Select:
       `merged_with_existing` | `duplicate_cleanup`),
     - `affected_sample_ids` (JSON-Array),
     - `created` automatisch.
     - Rules: read = owner-scoped.
2. `backend/internal/fusion/` (neu):
   - `serverFuse(incoming, candidates) → FusionDecision` pure-Go.
   - Adaptiver Radius `max(50, 2*hAcc_incoming, 2*max(hAcc_candidate))`.
   - Bounding-Box-Query gegen `localities` (nutzt
     `idx_localities_lat_lon`).
3. Hook `OnRecordAfterCreate("localities")` und
   `OnRecordAfterUpdate("localities")` (nur bei Koord-Änderung > 100 m):
   - Ruft `serverFuse`.
   - `MergeInto`: Samples umhängen, alte Locality löschen, Event
     emittieren.
   - `AmbiguousFlagForReview`: Flag setzen.
4. Test-Fixtures `backend/internal/fusion/testdata/`:
   - `kreuzwertheim_alle_test.go` (7 Samples → 2 Localities)
   - `wertheim_kreuzwertheim_alle_test.go` (17 Samples → 4 Localities)
   - `offline_collision_test.go`
   - `accuracy_edge_test.go`
   - Koordinaten aus Spec §5.5 — vom User anfordern, falls noch
     nicht im Repo.

**R6.2 — iOS verarbeitet Remap-Events**

1. `Core/Sync/RemapEventsPuller.swift` (neu) — pollt
   `/api/collections/locality_remap_events/records` mit `since`-
   Filter.
2. `Core/Persistence/LocalitiesStore`: `applyRemap(old, new,
   affectedSamples)` idempotent — wenn `old` lokal nicht mehr
   existiert, no-op.
3. UI-Notification über NotificationCenter: „3 Samples wurden mit
   Locality 'Am Wasser' zusammengeführt." (dezenter Toast, kein
   Modal).

**R6.3 — iOS Offline-Fusion**

1. `Core/Geo/LocalityFusion.swift` (neu) mit
   `offlineFuseLocality(sample:locallocalities:radius:)`.
2. Im AddSample-Flow eingehängt: wenn `locationSource ==
   .locationService` und Koords gesetzt → versuche Fusion mit lokalen
   Localities, sonst neue anlegen.
3. Unit-Tests: vier Tests aus Spec §5.5 (Sample 30 m nah →
   anhängen, 200 m → neu anlegen, leere Liste → neu, Boundary 50 m).

### Akzeptanzkriterium

- Fixture-Tests (Kreuzwertheim/Wertheim) ergeben exakt die in der
  Spec genannten Locality-Zahlen.
- Offline-Collision-Test: zwei simulierte Clients legen unabhängig
  Locality an gleichem Punkt an, Server mergt, Event landet beim
  Pull, beide Clients konvergieren.
- Doppel-Anwendung eines Remap-Events ist no-op (Idempotenz).

### Risiken

- Centroid-Update kann Locality so weit verschieben, dass neue
  Fusion-Runde fällig wird → bounded loop, max 3 Iterationen pro
  Hook-Run.
- Locality-Delete cascadet **nicht** Samples (Samples bleiben),
  Samples werden auf Target umgehängt — Hook muss FK-Reihenfolge
  exakt einhalten.

---

## R7 — Placemark-Pipeline live

**Status: pending.** Setzt R3.1 voraus.

### PR-Struktur

**R7.1 — Geocoding-Hook auf Locality-Lifecycle**

1. `backend/internal/enrichment/placemark.go` (neu):
   - Triggert auf `OnRecordAfterCreate("localities")` und
     `OnRecordAfterUpdate("localities")` (bei Koord-Änderung > 100 m
     oder fehlendem Placemark).
   - No-op wenn `locality.placemark.geocoding_source == manual`.
   - Sonst: Labelloc-Call (via `services/labelloc.go`, geocached) →
     Placemark-Hash bilden → `placemarks` lookup-or-create →
     `locality.placemark` setzen.
2. Hash-Algorithmus dokumentieren: NFC-normalisiert + lowercased +
   `|`-join der Felder `country|administrative_area|locality|postal_code`.
3. Idempotenz: Labelloc-Fehler → Retry-Queue, **niemals**
   Locality-Save scheitern lassen.

**R7.2 — Manual-Override-Endpoint**

1. Neue Custom-Route `PATCH /api/localities/:id/placemark`:
   - Auth: `RequireRecordAuth("users")`.
   - Body: Placemark-Felder.
   - Setzt `geocoding_source = manual`, lookup-or-create in
     `placemarks`, hängt an Locality.
2. Reset-Route `DELETE /api/localities/:id/placemark/override`:
   - Setzt `geocoding_source` zurück auf `backend-service`, triggert
     Re-Geocode.

**R7.3 — Backfill Bestand**

1. Migration `1700000020_phase_R7_backfill_placemarks.go`:
   - Iteriert über bestehende `samples.admin_units`-JSON-Snapshots.
   - Bildet pro Sample die Placemark-Daten, looked-up-or-creates.
   - Setzt `locality.placemark` der zugehörigen Locality.
   - Bestehende `excursions.admin_units` bleibt vorerst stehen
     (NEW-2).
2. Dry-Run-Modus: `--apply` Flag, sonst nur Report.

**R7.4 — `samples.admin_units` droppen**

Erst nach R7.3 erfolgreich + 1 Woche Beobachtung in Staging.
Eigene Migration, eigener PR.

### Akzeptanzkriterium

- Neue Locality bei Koord (49.79, 9.51) bekommt nach < 2 s ein
  Placemark mit `country = DE`.
- Manueller Override stickt: zweiter Labelloc-Call überschreibt nicht.
- Backfill-Dry-Run liefert sinnvollen Report; Apply läuft idempotent.

### Risiken

- Placemark-Hash-Kollisionen: NFC-Normalisierung muss in *Go-stdlib*
  identisch zu *Swift-Foundation* sein. Vor R7 als Spike testen.
- Bestehender Labelloc-Cache (`geocache`) bleibt erhalten — keine
  Duplikat-Calls.

---

## R8 — UI-Anpassungen

**Status: pending.** Setzt R4, R6, R7 voraus.

### Scope (gemäß Spec §7, im Repo-Kontext)

1. **AddSample-Sheet**: drei Modi „Jetzt im Feld", „Nachträglich",
   „Geplant" (letzteres wird R11). Klare LocationSource-Anzeige.
2. **Map-View**: Cluster-Pins, Locality als Anker.
3. **Locality-Editor**: Fusions-UI („Mit Locality 'X' zusammenführen?"),
   Badge bei `needs_human_review`.
4. **Sample-ID-Generator**: Template-Editor (`<YY><MM><DD>/<seq>`).
5. **Filter**: Fieldtrip, Datum, Land, hat-Notes, hat-Koordinate.

Jeder Punkt ist ein eigener PR — diese Phase splittet sich
horizontal über Wochen.

### Akzeptanzkriterium

- A11y-Checkliste aus `.claude/rules/ACCESSIBILITY-IOS.md` für jedes
  neue Atom durchlaufen.
- Design-System-Konformität (`.claude/rules/DESIGN-SYSTEM.md`) —
  keine Magic-Numbers, keine Hex-Farben.

---

## R9 — Export

**Status: pending.** Setzt R7 voraus.

### Scope

1. **GPX**: Waypoints aus Samples.
2. **CSV**: flach, eine Zeile pro Sample mit Joins (Fieldtrip,
   Locality, Placemark).
3. **JSON**: vollständige verschachtelte Struktur.

Bestehende `/api/export`-Route erweitert (oder neue Routen pro
Format).

---

## R10 — Daten-Migration Bestand

**Status: pending.** Setzt R5, R6, R7 voraus.

### Scope (Spec §8)

1. `pb_data/`-Backup verifizieren (`docs/DISASTER_RECOVERY.md`).
2. Migrations-Skript (eigene Migration, Dry-Run + `--apply`):
   - Samples ohne Fieldtrip → Auto-Trip „Migrated 2026-XX-XX".
   - Samples ohne Locality → 1:1-Locality erzeugen → Server-Fusion
     drüberlaufen lassen.
   - `location_source` per Heuristik (siehe R3.2).
3. Smoke-Test-Daten aus Spec §5.5 als Fixture verewigen.

---

## R11 — Planning-Feature

**Status: pending.** Setzt R7 voraus.

### Scope

`fieldtrips.planned_locality` (Relation → localities, optional).
UI: Locality vorab anlegen ohne Sample, Trip mit `planned_locality`
ausstatten. Im Feld füllt sich der Trip dann automatisch mit
Samples.

---

## Anhang A — Konventionen für diesen Refactoring-Strang

- **Branch-Konvention**: `refactor/R<n>-<slug>`, z. B.
  `refactor/R2-rename-excursion-to-fieldtrip`.
- **Commit-Konvention**: Conventional Commits gemäß
  `.claude/rules/COMMITS.md`, Scope-Tag: `(refactor)` für
  Quershnitts-Themen, sonst `(backend)`/`(ios)`/`(ci)` etc.
- **Migrations-Nummerierung**: `1700000014_phase_R<n>_<slug>.go`
  aufwärts.
- **PHASES_REFACTOR.md zuerst aktualisieren**, wenn ein Status
  wechselt. Konsistent zur Regel in `CLAUDE.md`.
- **Kein Phase-Skipping**, kein Commit-Squashing über Phase-
  Grenzen.

---

## Anhang B — Risiko-Heatmap

| Phase | Risiko | Mitigation |
|---|---|---|
| R2 | Datenmigration kaputt | Pre-snapshot `pb_data/`, idempotente Migration |
| R2 | iOS-Build bricht | Commit 2 erst nach grünem xcodebuild |
| R3 | Required-vs-optional-Schalter | Defaults setzen, niemals Spalte ohne Default als required hinzufügen |
| R5 | Sync-Konflikt-Schleifen | Bounded retries, exponential backoff |
| R6 | Fusion-Loop | Bounded iterations (max 3 pro Hook-Run) |
| R6 | Centroid-Drift | Nur GPS-Samples für Centroid, Manual-Source ignorieren |
| R7 | Placemark-Hash-Kollision | NFC-Normalisierung-Spike Go ↔ Swift |
| R7 | Backfill-Timeout | Chunked Processing, idempotent |
| R10 | Datenverlust beim Backfill | Dry-Run-First, --apply nach Review |

---

## Anhang C — Offene Punkte zum Klären während der Phasen

- **R3.1**: Hat `placemarks` ein `owner`-Feld oder ist es eine
  Reference-Table ohne Owner? **Empfehlung im Plan: ohne Owner.**
  User-Bestätigung in der R3.1-PR-Discussion.
- **R5.0** (ADR-NEW-8): WebSocket oder Polling? Eigener ADR.
- **R6.1**: Genauer Algorithmus für Centroid-Update bei Merge —
  arithmetisches Mittel oder gewichteter Median? Spec sagt
  „gewichteter Mittelwert" — als Default akzeptiert.
- **R7.1**: MTB-Daten — bleiben sie als JSON auf `fieldtrips`, oder
  wandern sie in eine eigene `mtb_sheets`-Reference-Table mit
  Dedup? Spec ignoriert MTB; **Empfehlung: vorerst belassen**.
