# Gap-Analyse — Sample / Locality / Placemark Refactoring

Stand: 2026-05-22 · Quelle: `fieldsampling-refactoring-plan.md`,
Ist-Zustand aus `inventory.md`. Phase 0 nach Spec — **kein Code wird
durch dieses Dokument geändert**.

Diese Datei listet pro Zielobjekt: **Status quo → Soll → Diff →
Migrationspfad**. Am Ende: alle offenen Punkte aus Spec §1 plus
Mismatches, die in der bestehenden Codebasis aufgefallen sind.

---

## 0. Namens-Entscheidung: Excursion → Fieldtrip

Vom User in der Phase-0-Abnahme verbindlich festgelegt:
**`Excursion` wird zu `Fieldtrip` umbenannt.**

Auswirkung:
- Backend-Collection `excursions` → `fieldtrips`.
- Hooks, Enricher, Codes-Pakete, API-Routen, OpenAPI-Spec.
- iOS-Modelle (`Excursion`, `LocalExcursion`), Feature-Folder
  `Features/Excursions/`, alle Call-Sites.
- Migrationsskript braucht Daten-Rename (in-place
  `rename_collection`) plus Foreign-Key-Updates auf `samples.excursion →
  samples.fieldtrip`.
- UI-Strings auf Deutsch bleiben **„Exkursion"** — das ist der Domain-Begriff
  des Sammlers (siehe `CLAUDE.md`-Glossar). Nur Code-Identifier ändern sich.

Konsequenz: Diese Umbenennung ist eine Querschnitts-Aufgabe und sollte
**vor** den Schema-Migrationen aus Spec §2 stehen — sonst doppeln sich
Diffs.

---

## 1. Sample

### Status quo

PocketBase `samples`:
- `code`, `original_code`, `excursion` → wird zu `fieldtrip`
- `owner` (relation → users)
- `collected_from`, `collected_to` (Date)
- `lat`, `lon` (required), `altitude_m`, `accuracy_m`
- `notes` (Editor)
- `admin_units`, `mtb` (JSON-Snapshots)
- `marked` (Bool)
- `client_uuid`, `client_updated_at`

iOS `Sample` (Decodable) + `LocalSample` (GRDB).

### Soll laut Spec §2

- `beginDate` (required, DateTime-Typ), `endDate` (optional, DateTime-Typ), `isAllDay`,
  `timeZone` (IANA-Identifier, z. B. `Europe/Berlin`)
- `sampleID` (Text, required, indexed, **nicht** unique projektweit sondern unique pro owner)
- `notes` (optional)
- `locationSource` (Enum: `user | locationService | sample | locality`,
  required)
- `latitude/longitude/altitude/horizontalAccuracy/verticalAccuracy`
  (alle optional)
- `version` (number, required, default 1) — monoton wachsend
- `fieldtrip` (relation, required)
- `locality` (relation, required)

### Diff

| Spec-Feld | Ist-Feld | Aktion |
|---|---|---|
| `beginDate` | `collected_from` | rename + Semantik bestätigen |
| `endDate` | `collected_to` | rename |
| `isAllDay` | – | **NEU**, default `false` |
| `timeZone` | – (implizit Berlin) | **NEU**, default `Europe/Berlin`, IANA |
| `sampleID` | `code` | rename, Index bleibt non-unique |
| `notes` | `notes` | OK |
| `locationSource` | – | **NEU**, Enum mit 4 Cases, default-Heuristik bei Migration |
| `latitude` | `lat` | rename (optional gemäß Spec), heute required |
| `longitude` | `lon` | rename, dito |
| `altitude` | `altitude_m` | rename, Unit-Postfix entfernen |
| `horizontalAccuracy` | `accuracy_m` | rename |
| `verticalAccuracy` | – | **NEU**, optional |
| `version` | – | **NEU**, required, default 1 |
| `fieldtrip` | `excursion` | rename (siehe §0) |
| `locality` | – (heute nur an `excursions.locality`) | **NEU am Sample**, required (siehe Spec 1.6) |
| `original_code` | `original_code` | bleibt (Implementations-Detail Hook) |
| `admin_units`, `mtb` | – | künftig **nicht** mehr am Sample, sondern über `locality.placemark` (siehe §3) |
| `marked` | `marked` | bleibt (Feature aus Phase 14b) |
| `client_uuid`, `client_updated_at` | bleibt | bleibt — neben `version` als zweiter Layer Idempotenz |

### Migrationspfad

1. PocketBase-Migration `XXX_phase0_rename_excursion_to_fieldtrip.go`:
   - `collections.RenameCollection("excursions", "fieldtrips")`.
   - Spalte `samples.excursion → samples.fieldtrip`.
   - Indexe umbenennen (`idx_excursions_*` → `idx_fieldtrips_*`).
2. PocketBase-Migration für die neuen Spalten auf `samples`:
   - `is_all_day` (Bool, default false), `time_zone` (Text, default
     `Europe/Berlin`).
   - `version` (Number, default 1, required).
   - `location_source` (Select: `user`, `location_service`, `sample`,
     `locality`).
   - `locality` (Relation → `localities`, required für *neue* Records,
     für Bestand backfill).
3. Field-Renames:
   - `code → sample_id`
   - `collected_from → begin_date`
   - `collected_to → end_date`
   - `lat → latitude`, `lon → longitude`
   - `accuracy_m → horizontal_accuracy`, `altitude_m → altitude`
   - `vertical_accuracy` (Number, optional) neu
4. Daten-Backfill für Bestand:
   - `locationSource` per Heuristik (Spec §8): hat das Sample
     `horizontal_accuracy != null` → `location_service`, sonst → `user`.
   - `locality`: pro Bestands-Sample, das noch keine Locality kennt,
     wird beim Migrations-Run eine 1:1-Locality erzeugt; danach läuft
     der Server-Fusion-Pass.
5. Stripped: `admin_units`/`mtb` von `samples` entfernen, sobald
   Placemark-Pfad (§3) live ist. **Erst nach** Backfill, damit nichts
   verloren geht.

> ⚠ Risiko: `client_updated_at` (LWW) vs. `version` (monoton). Beide
> behalten — siehe offene Frage 1.5.

---

## 2. Fieldtrip (ex Excursion)

### Status quo

`excursions` mit Centroid, denormalisierten Geo-Feldern (country,
admin_area, day_of_year), Permits, Astro-Snapshot, Suggested-Locality.

### Soll laut Spec §2

- `id`, `title`, `beginDate`, `endDate`, `notes`, `version`, `created`,
  `updated`.
- Optional: `plannedLocality` (Relation → localities) für die
  Planungs-Funktion (Spec §11.10).

### Diff

| Spec-Feld | Ist-Feld | Aktion |
|---|---|---|
| `title` | `name` | rename |
| `beginDate` | `started_at` | rename |
| `endDate` | `ended_at` | rename |
| `notes` | – | **NEU**, optional |
| `version` | – | **NEU** |
| `plannedLocality` | – | **NEU**, Phase 10 (Planung) |
| – | `collecting_day` | **behalten** als denormalisierter Helfer (Codes-Vergabe) |
| – | `night_excursion` | **behalten** (UI/Filter) |
| – | `centroid_lat/lon` | **behalten** (UI-Centroid) |
| – | `admin_units/mtb/astro` | offen: bleiben hier oder wandern in eine `Placemark`-/separate Cache-Collection? Siehe offene Frage NEW-2. |
| – | `day_of_year/country/admin_area` | denormalisiert für Filter, **behalten** bis OpenAPI-Filter umgebaut sind |
| – | `permit_*` | **behalten**, ist Phase-8-Feature |
| `locality` (Spec verschweigt) | `locality` + `suggested_locality` | **behalten**; die Spec-`locality` wäre am `Sample` |

### Migrationspfad

1. Rename-Migration (siehe §0).
2. Spalten-Adds: `notes`, `version`.
3. Spalten-Renames: `name → title`, `started_at → begin_date`,
   `ended_at → end_date`.
4. Felder, die die Spec nicht erwähnt, bleiben **erstmal stehen** — sie
   sind aktive Features (Permits, Astro, Filter). Entscheidung darüber
   gehört in Phase 1 als Designfrage NEW-2.
5. Phase 10 (Planning) führt `planned_locality` ein.

---

## 3. Locality

### Status quo

`localities`:
- `name` (required), `centroid_lat`, `centroid_lon`, `radius_m`, `notes`
- `owner`
- **keine** `client_uuid`/`client_updated_at`
- **keine** `placemark`-Relation
- **keine** `locationSource`
- **keine** `horizontal_accuracy`/`vertical_accuracy`
- **kein** `location_number`

### Soll laut Spec §2

- `latitude/longitude/altitude/horizontalAccuracy/verticalAccuracy`
  (required für lat/lng)
- `locationSource` (Select, required)
- `notes` (optional)
- `locationNumber` (optional, projektbezogene FO-Nummer, nicht unique)
- `placemark` (relation → placemarks, optional, single)
- `version` (number)

### Diff

| Spec-Feld | Ist-Feld | Aktion |
|---|---|---|
| `latitude` | `centroid_lat` | rename + Semantik klären: aktuell ist das ein berechneter Cluster-Centroid, Spec impliziert einen einzigen Locality-Punkt → kompatibel, aber Namensschärfe gewinnt mit `latitude` |
| `longitude` | `centroid_lon` | rename |
| `radius_m` | – (Spec nicht erwähnt) | **behalten**? Spec sagt nichts. Vermutlich obsolet, weil Fusion den Cluster jetzt anders modelliert. Siehe NEW-3. |
| `altitude/horizontalAccuracy/verticalAccuracy` | – | **NEU**, Quelle: erstes Sample |
| `locationSource` | – | **NEU**, required |
| `locationNumber` | – | **NEU**, optional |
| `placemark` | – | **NEU**, Relation single optional |
| `version` | – | **NEU** |
| `client_uuid`, `client_updated_at` | – | **NEU**, da Localities jetzt vom Client offline erzeugt werden (Spec §5.1) und über Sync wandern |
| `name` | `name` | Spec **erwähnt `name` nicht**. Bleibt sinnvoll für UI ("Am Wasser", "Waldstück"). Empfehlung: behalten, als optional markieren. Siehe NEW-4. |

### Migrationspfad

1. Spalten-Adds: `latitude` (Number), `longitude` (Number),
   `altitude`, `horizontal_accuracy`, `vertical_accuracy`,
   `location_source`, `location_number`, `placemark` (Relation),
   `version`, `client_uuid`, `client_updated_at`.
2. Daten-Migration: `centroid_lat → latitude`, `centroid_lon →
   longitude`.
3. Spalten-Drops am Ende: `centroid_lat`, `centroid_lon` (nach Backfill),
   evtl. `radius_m` (siehe NEW-3).
4. Backfill `location_source` per Heuristik (siehe Sample).
5. Backfill `placemark` ist optional und wird vom Server-Geocoding-Pass
   (§3 dieser Datei) gefüllt, sobald Placemark-Collection live ist.

---

## 4. Placemark (neu)

### Status quo

**Existiert nicht.** Reverse-Geocoding-Ergebnisse leben heute in
`samples.admin_units` (JSON) und propagieren auf
`excursions.admin_units` (Enricher in `internal/enrichment/`).
Backend-Service `labelloc` wird verwendet und gecacht in `geocache`.

### Soll laut Spec §2 + §6

Neue Collection `placemarks`:
- `country` (ISO 3166-1 alpha-2, required)
- `administrativeArea`, `subAdministrativeArea`, `locality`,
  `subLocality`, `postalCode`, `name`, `thoroughfare` (optional)
- `geocodingSource` (Select: `backend-service | manual`)
- `geocodingServiceVersion` (Text, optional)
- `geocodingDate` (Date)
- Unique-Hash (siehe §6.3): lowercased, NFC-normalisierte
  Konkatenation der Schlüssel-Felder mit `|`. **Im Backend gebildet.**

### Diff

Komplette Neu-Collection. Plus: aus dem Sample wandert die JSON-Spalte
`admin_units` heraus — die Information wird `Locality.placemark`.

### Migrationspfad

1. Migration `placemarks` anlegen mit den Feldern oben + Unique-Index
   auf Hash-Spalte.
2. Hook in `internal/enrichment/`:
   - Trigger `OnLocalityCreate` und `OnLocalityUpdate` (bei
     Koord-Änderung > 100 m).
   - Wenn `locality.placemark` schon gesetzt und
     `placemark.geocoding_source = manual` → no-op.
   - Sonst Labelloc-Call → Hash bilden → `placemarks` lookup-or-create
     → `locality.placemark` setzen.
3. Bestehende `admin_units`-Snapshots an `samples` werden einmalig in
   Placemarks überführt (Migrations-Pass), `locality.placemark`
   gesetzt, dann `samples.admin_units` und `excursions.admin_units`
   leeren / Spalten entfernen.
4. Custom-Endpoint `PATCH /api/localities/:id/placemark` für manuelle
   Korrektur (Spec §6.2). Setzt `geocoding_source = manual`.
5. `geocache` bleibt als HTTP-Response-Cache erhalten — er deduplisiert
   labelloc-Calls, während `placemarks` die *parsed entity* dedupliziert.

> Hinweis: Der vorhandene MTB-Lookup (`mtb`-JSON-Felder) ist **nicht**
> Teil der Spec. Empfehlung: MTB nicht in Placemarks pressen, sondern
> als separates Enrichment-Feld auf der `Fieldtrip`-Collection
> bestehen lassen. Siehe NEW-2.

---

## 5. LocationSource

### Status quo

**Existiert nicht.** Es gibt nur ein UI-Enum
`LocationProvider.Status` (idle/locating/fixed/failed), das das
GPS-Lifecycle abbildet, **nicht** die Provenienz eines persistierten
Datensatzes.

### Soll laut Spec §3

iOS:
```swift
enum LocationSource: Int, Codable {
  case user = 0, locationService = 1, sample = 2, locality = 3
}
```

PocketBase Select-Field mit String-Variante; intern Int.

### Diff & Migrationspfad

1. Backend-Select-Field auf `samples` und `localities` (jeweils
   required).
2. iOS-Enum in `Core/Models/LocationSource.swift` (neu).
3. Wire-Format String, lokale GRDB-Spalte Int.
4. Backfill (Spec §8): GPS-Genauigkeit vorhanden → `location_service`,
   sonst → `user`.

---

## 6. Sync: Outbox & Realtime

### Status quo

- iOS hat **keine separate `pending_mutations`-Tabelle**. Der
  Sync-Status lebt direkt auf den `Local*`-Records
  (`syncStatus: pending|syncing|synced|failed` + `syncError`).
- `SyncRunner` macht 30 s Retry-Loop und kann per `kick()` getriggert
  werden.
- Pro-Collection-Clients in `Core/PocketBaseClient/`.
- Idempotenz heute über `client_uuid` + `client_updated_at` (LWW).
- **Kein Realtime-WebSocket** — Push-Updates kommen über
  Enrichment-Polling.

### Soll laut Spec §4

- Outbox-Queue `pending_mutations`: jede lokale Änderung als Eintrag
  mit `op | entity-typ | payload | attempts | lastAttempt | lastError`.
- Realtime-Subscription via WebSocket-Client (oder REST-Polling als
  Fallback).
- Version-basiertes Conflict-Handling: `version` inkrementiert vor
  Push, Konflikt → 409 → LWW per `updated`-Timestamp + manuelle
  Konfliktanzeige für `notes`.
- Abarbeitungsreihenfolge:
  `Placemark → Locality → Fieldtrip → Sample` (FK-Reihenfolge).

### Diff

| Bereich | Status quo | Soll | Aufwand |
|---|---|---|---|
| Lokale Outbox | implicit in Local*-Records | explizite Tabelle | mittel |
| Realtime | – | WebSocket gegen PB | groß (PB-WebSocket-Client für Swift fehlt) |
| Conflict-Handling | LWW über `client_updated_at` | `version` (monoton) + LWW | mittel |
| Reihenfolge | implizit (Excursion-zuerst-im-Hook) | explizit FK-Reihenfolge | klein |

### Migrationspfad

1. Schritt-für-Schritt **nicht** in Phase 0 entscheiden — Spec macht
   das in §10 Phase 4 (SyncCoordinator + Outbox).
2. Erst `version`-Feld pro betroffener Collection ausrollen, dann
   Outbox-Tabelle einführen, dann WebSocket-Layer.

> Realtime-Spec sagt explizit "JS-SDK-Äquivalent" — der iOS-Client hat
> heute keinen WebSocket-Client. Das ist ein eigener Brocken.

---

## 7. Locality-Fusion (Server smart, Client trivial)

### Status quo

- Es gibt `nearestLocalityID()` in `internal/enrichment/excursion.go`,
  das die *räumlich nächste owner-scoped Locality* sucht und in
  `excursion.suggested_locality` schreibt — **keine Fusion**, nur
  Vorschlag.
- Es gibt keinen client-seitigen Algorithmus.
- Es gibt keinen `LocalityRemap`-Event-Mechanismus.

### Soll laut Spec §5

- Client: `offlineFuseLocality(sample, localLocalities)` mit Radius
  R = 50 m, nächstgelegener Kandidat oder neu anlegen. **Plattform-
  identisch trivial.**
- Server: adaptiver Radius (`max(50, 2*hAcc_incoming, 2*max(hAcc_candidate))`),
  Ambiguitäts-Behandlung, Centroid-Update (gewichtet, nur GPS-Samples),
  Merge oder Flag `needsHumanReview`.
- `LocalityRemap`-Event im Sync-Stream:
  `{oldLocalityId, newLocalityId, reason, affectedSampleIds}`.
  Idempotent.
- UI: dezente Notification bei Merge, Badge bei Ambiguität.

### Diff & Migrationspfad

1. **Server zuerst** (Spec §10 Phase 5a):
   - Neue Spalte `localities.needs_human_review` (Bool).
   - Hook `OnLocalityCreate`/`OnLocalityUpdate` ruft Fusion-Funktion.
   - `LocalityRemap`-Events: neue Collection
     `locality_remap_events` mit `old_locality_id`, `new_locality_id`,
     `reason`, `affected_sample_ids` (JSON), `processed_by` (per-client
     pivot oder ack-collection).
2. iOS-Sync-Layer (5b): Event-Pull beim Sync-Pass, lokales
   Umhängen + UI-Notification + alte Locality löschen. **Idempotent.**
3. iOS-Offline-Fusion (5c): `Core/Geo/LocalityFusion.swift` (neu) mit
   `offlineFuseLocality()`. Wird im AddSample-Flow eingehängt.

> Test-Fixtures (Spec §5.5): Koordinaten aus Kreuzwertheim/Wertheim
> brauchen wir als Server-Test-Daten. Liegen noch nicht im Repo.

---

## 8. Date / Zeitzone

### Status quo

- `collected_from`/`collected_to` Date-Felder, ohne explizite TZ.
- Hook konvertiert für `CollectingDay` nach `Europe/Berlin`.
- Es gibt kein `time_zone`-Feld und kein `is_all_day`-Feld.

### Soll laut Spec §1

- UTC ISO-8601 in der Speicherung.
- IANA-Identifier (`Europe/Berlin`) als TZ-Spalte.
- `isAllDay` steuert nur Darstellung — Werte bleiben präzise UTC,
  Konvention 00:00:00–23:59:59 *lokal*.

### Diff

| Feld | Aktion |
|---|---|
| `samples.time_zone` (Text, default `Europe/Berlin`, IANA) | **NEU** |
| `samples.is_all_day` (Bool, default `false`) | **NEU** |
| Sicherstellen, dass DB nur UTC speichert | Migration prüft und konvertiert ggf. Bestand |
| iOS: TZ-Roundtrip-Tests (`DateFormatter` mit IANA) | **NEU**, Spec §9 |

---

## 9. Test-Strategie (Diff zu §9 der Spec)

### Status quo (aus PROJECT_PLAN.md/CLAUDE.md)

- Backend: `go test ./...` muss grün sein. > 80 % Coverage auf
  `codes/`, `grouping/`.
- iOS: Unit-Tests für `Core/Sync/`, `Core/Geo/codes/` (existiert
  derzeit als `Core/Location/`).

### Diff

Spec verlangt zusätzlich:
- Server-Integration-Tests gegen lokal laufende PB-Instanz
  (Docker-Compose) für Fusion (Kreuzwertheim, Wertheim,
  Offline-Collision, Accuracy-Edge).
- E2E-Sync-Tests mit zwei Client-Instanzen → konvergierender State.
- Property-Based-Tests (optional, Go-side) auf Fusion.
- UI-Tests im Flugmodus.

Konsequenz: bestehende Test-Pyramide wird auf Server-Integration
ausgebaut. Liegt in Spec-Phase 5.

---

## 10. Reihenfolge (Empfehlung im Kontext des Repos)

Die Spec gibt §10 als Implementierungsreihenfolge vor. Im Kontext des
**bereits gelaufenen Phase 0–11 + 14**-Stands schlagen wir vor:

| Spec-Phase | Reihenfolge im fwd-Repo | Anmerkung |
|---|---|---|
| 0 (Inventur) | jetzt — fertig mit diesem Dokument | |
| 1 (Designfragen) | sofort als Folgeschritt | siehe §11 unten |
| **NEU (Querschnitt)** | Rename `Excursion → Fieldtrip` (Migration + Code) | Vor allem anderen, sonst doppeln sich Diffs |
| 2 (PB-Schema) | dann | Sample / Locality / Placemark Felder, ohne `version`-Logik |
| 3 (iOS-Modelle) | parallel zu 2 möglich, sobald Schema gefroren | |
| 4 (Sync) | nach 2–3 | Outbox + `version` + Realtime in dieser Reihenfolge |
| 5 (Fusion) | nach 4 | Server-first |
| 6 (Geocoding-Backend) | parallel zu 5 möglich | |
| 7 (UI) | nach 5 + 6 | |
| 8 (Export) | nach 7 | |
| 9 (Daten-Migration) | nach 8 | |
| 10 (Planning) | optional, später | |

PHASES.md muss diese neue Phasen-Numerik gegenüber dem bestehenden
Phasen-Schema (1–14 inkrementell) klar abgrenzen. Empfehlung: das
hier wird ein eigenes Top-Level-Initiative, parallel zu PHASES.md
geführt — vielleicht als `PHASES_REFACTOR.md`.

---

## 11. Offene Fragen (vor Spec-Phase 2 zu entscheiden)

Spec §1 listet sieben Punkte. Plus zusätzliche Mismatches, die sich
aus dem Ist-Stand ergeben (`NEW-*`).

| # | Frage | Spec-Empfehlung | Repo-Kontext / unsere Empfehlung |
|---|---|---|---|
| 1.1 | `Sample.notes` required mit leerem String erlaubt oder optional? | optional, UI normalisiert leer → nil | **OK so**. iOS `Sample.notes` ist heute optional (String?). Backend `notes` ist Editor-Feld und faktisch optional. Nichts zu tun außer Konvention dokumentieren. |
| 1.2 | `Sample.location` (Koords) optional am Modell, required am Use-Case? | optional am Modell | **OK, aber Bruch zum Ist-Stand**: heute sind `lat`/`lon` required. Migration muss die Pflicht aufheben. Frage: was passiert mit Bestands-Samples bei späterer manueller Eingabe? UI-Workflow muss „nachträglich" sauber unterstützen. |
| 1.3 | `Locality.notes` / `Locality.location` | location required, notes optional | **OK**. `name` der heutigen Locality wird zusätzlich behalten (siehe NEW-4). |
| 1.4 | Placemark-Felder-Tabelle vervollständigt | siehe Spec-Tabelle | **OK**. ISO-2-Country required, Rest optional. Hash-Bildung im Backend (NFC+lowercased+`|`-join). MTB bleibt **außerhalb** Placemark (siehe NEW-2). |
| 1.5 | `Sample.version` behalten oder `modificationDate` reicht? | version behalten, robuster | **OK**. Wir behalten dann *beides*: `version` (monoton, Conflict-Detection) **und** `client_updated_at` (LWW-Fallback bei `notes`-Konflikten). |
| 1.6 | `Sample.fieldtrip` required oder optional? | required, Auto-Trip beim Anlegen | **OK**, ist bei uns über den Hook bereits so. Backfill prüfen für ältere Records ohne `excursion`. |
| 1.7 (impl.) | Locality am Sample required? Spec impliziert es | Spec §2: `locality` required am Sample | **Diskutieren**: heute kennt nur die `excursion` eine `locality`. Spec verschiebt das. → impliziert Schema-Diff + Backfill für **alle** Bestands-Samples. Aufwand sichtbar machen. |
| NEW-1 | Excursion vs. Fieldtrip — alle Code-Touchpoints | (vom User entschieden: rename) | siehe §0 oben |
| NEW-2 | `admin_units`/`mtb`/`astro`/`day_of_year`/`country`/`admin_area`/`permit_*` an `fieldtrips` — was bleibt, was wandert? | – | **Empfehlung:** `admin_units` wandert nach `placemark` (über `locality.placemark`), aber als Snapshot auf der `Fieldtrip` für Filter-Performance erhalten bleiben (denormalisiert). `mtb` bleibt JSON am Fieldtrip (Spec ignoriert MTB). `astro` bleibt am Fieldtrip. `permit_*` bleibt. `day_of_year`/`country`/`admin_area` bleiben, sind sonst Backwards-Breaking für die OpenAPI-Filter. |
| NEW-3 | `Locality.radius_m` (existiert heute) | – | **Empfehlung:** beibehalten. Heute wird er als Cluster-Radius berechnet; in der Fusion-Welt kann er als „beobachtete Streuung" dokumentiert bleiben. Kein Schema-Drop. |
| NEW-4 | `Locality.name` (existiert heute) | Spec ignoriert es | **Empfehlung:** behalten, als optional. Der Sammler vergibt sprechende Namen („Am Wasser"); ohne ihn wird die UI unhandlich. |
| NEW-5 | `geocache` (HTTP-Response-Cache) vs. `placemarks` (parsed entity) | – | **Empfehlung:** beide behalten. Sie deduplizieren auf verschiedenen Ebenen. |
| NEW-6 | Wer macht den ersten Backfill-Pass für `locality` am Sample? | – | **Empfehlung:** Migrations-Skript erzeugt 1:1-Locality pro Bestands-Sample, danach **derselbe** Server-Fusion-Hook (Phase 5a). Spec sagt das in §8 schon — wichtig für unsere Implementierungsreihenfolge. |
| NEW-7 | OpenAPI-Spec (`docs/openapi.yaml`) | – | **Empfehlung:** wird ebenfalls aktualisiert in Phase 2 (PB-Schema-Migration). Sonst weicht die Doku ab. |
| NEW-8 | Realtime / WebSocket-Client für iOS | Spec verlangt es | **Diskutieren:** Eigenimplementierung WebSocket-Subscribe gegen PocketBase ist nicht trivial. Alternative: aggressives Polling-Intervall mit Conditional-Requests. Vor Phase 4 als ADR fixieren. |
| NEW-9 | `PHASES_REFACTOR.md` vs. weiter in `PHASES.md`? | – | **Empfehlung:** eigenes Dokument für die Refactoring-Initiative, damit die bestehende Phasen-Geschichte lesbar bleibt. |

---

## 12. Was als nächstes passiert (kein Code)

1. Du gehst diese Gap-Analyse durch und bestätigst die Antworten zu
   §1.1–1.6 (Spec) + NEW-1…NEW-9 (Repo-spezifisch) — oder änderst sie.
2. Sobald die Designfragen entschieden sind, beantragen wir Spec-Phase 2:
   PB-Schema-Migration als eigene PR(s), strikt inkrementell, jede
   Migration einzeln testbar.
3. Eine `PHASES_REFACTOR.md` wird angelegt, sobald Phase 1 abgenickt
   ist.
