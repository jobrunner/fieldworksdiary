# PHASES.md — Phasen-Status

Lebendiger Status-Tracker pro Phase. **Wenn sich an einem Phasenstatus
etwas ändert (Schritt erledigt, Phase abgeschlossen, neue Phase
gestartet), DIESE DATEI zuerst aktualisieren** — danach erst
weiterarbeiten. Damit hat eine neue Claude-Session genug Kontext, um
nahtlos weiterzumachen.

Inhaltliche Beschreibung der Phasen siehe `PROJECT_PLAN.md` §11. Diese
Datei trägt nur den Status, die Akzeptanzkriterien und offene Punkte.

Status-Legende: `pending` · `in progress` · `done` · `blocked`

**Aktive Phase: Phase O (Ortus-Ortsdaten am Sample) in progress (gestartet 2026-11-09, Branch `feat/ortus-sample-ort`) — O1 (Backend) done 2026-11-09, O2 (iOS) implementiert – wartet auf Test durch Jo, O3 (Backfill/Aufräumen) offen; parallel offen: Phase 14 in progress (UI-Redesign Home + Sample-Foto, gestartet 2026-05-20). Phasen 0–11 + 10 done. Pending: Phase 12 (Production-Härtung — Color-Tokens/A11y-Audit wandern in 14) und Phase 13 (Tile-Caching / Offline-Map). Vor App-Store-Submit stehen menschliche Setup-Schritte (Apple-Dev-Konto, Privacy-URL etc.) — siehe Ende von Phase 11d. Phase 9 (FloraIncognita) zurückgestellt — derzeit nicht eingeplant.**

---

## Phase 0 – Bootstrap

**Status: done** (verifiziert am 2026-05-09: `go build` ✓,
`docker compose build` ✓, lokales `/api/health` → 200,
`xcodebuild ... build` ✓)

Ziel: Repo lauffähig machen, leeres Backend startet, iOS-App kann sich
verbinden und Health-Status anzeigen.

Akzeptanzkriterium: `docker compose up --build` startet PocketBase, die
iOS-App lässt sich öffnen, Endpoint kann gesetzt und persistiert werden,
Health-Indikator wird grün.

Aufgaben:
- [x] Repo-Layout (`backend/`, `ios/`, `docs/adr/`)
- [x] `docker-compose.yml` für Backend-Service
- [x] Minimaler `backend/main.go` (PocketBase als Library, leeres Schema)
- [x] `backend/Dockerfile` (multi-stage Go-Build)
- [x] iOS-Projekt via xcodegen (`ios/project.yml`)
- [x] Endpoint-Konfigurations-Screen, persistiert in UserDefaults
- [x] Health-Check ans `/api/health`, "verbunden / nicht verbunden"-Anzeige
- [x] `docker compose up --build` einmal lokal verifiziert
- [x] iOS-Build via `xcodebuild` einmal verifiziert

Notizen:
- `ATS`: für Dev-HTTP-Verbindungen ist `NSAllowsLocalNetworking`
  in der `Info.plist` gesetzt.
- PocketBase-Admin nach erstem Start unter `http://localhost:8090/_/`
  einrichten (Account erstellen).

---

## Phase 1 – Core-Schema und Code-Vergabe

**Status: done** (verifiziert am 2026-05-10 per Smoke-Test:
4 Samples über 3 Sammeltage, Codes `260509/1`, `260510/1`, `260510/2`,
`260511/1` korrekt vergeben, Cutoff 5h um Mitternacht greift, gleiche
Fieldtrip bei gleichem Sammeltag, Zeitfenster wird je Sample
erweitert. iOS-UI: build ✓, simulator-test offen.)

Ziel: Drei-Ebenen-Datenmodell im Backend, automatische Code-Vergabe und
Default-Exkursionszuordnung beim Sample-Insert.

Akzeptanzkriterium: Mehrere Samples eines Tages landen automatisch in
einer Exkursion, korrekte Codes (`YYMMDD/N`).

Aufgaben:
- [x] Migration `1700000001_init_app_collections.go`: `localities`,
      `fieldtrips`, `samples`, `sample_sequences`
- [x] `internal/codes/`: pure `CollectingDay(timestamp, cutoff_hour)`
      und `FormatCode(day, seq)` — 100 % Coverage
- [x] `internal/grouping/`: pure `FindOrCreate`, `ExpandWindow`,
      `SpansMidnight` mit Repo-Interface — 89.5 % Coverage
- [x] `internal/hooks/sample_create.go`: PocketBase-`Repo`-Adapter +
      atomare Sequenz-Allokation + Hook-Registrierung
- [x] Hook `OnRecordBeforeCreateRequest("samples")` setzt `code`,
      `fieldtrip`, `user_id`
- [x] iOS: `+`-Screen mit `LocationProvider` (CoreLocation) und
      `SampleClient` (HTTP POST) → zeigt vergebenen Code

Phase-1-Limitierungen, die bewusst in spätere Phasen geschoben sind:
- `user_id = "default"` fest verdrahtet, kein Auth (Phase 3+)
- Schema-`Required` für `code`/`fieldtrip`/`user_id` ausgeschaltet,
  weil PocketBase-Validation **vor** dem Hook läuft. Hook ist Single
  Source of Truth für diese Felder; Integritätstest = Smoke-Test.
- Sequenz-Allokation: SELECT + INSERT/UPDATE in Transaction.
  Race-Condition-tauglich für Single-Device-Single-User; Multi-Device
  kommt mit Sync (Phase 3).
- Open Rules (`""` für jeden) — wird mit Auth (späterer Phase) ersetzt.

---

## Phase 2 – Reverse-Geocoding, MTB und Astro

**Status: done** — alle drei Chunks geliefert und verifiziert (2a am
2026-05-10 gegen Self-Hosted-Endpoints, 2b gegen timeanddate.com, 2c
Build + App-Launch im iOS-Simulator).

Ziel: Asynchrone Anreicherung der Samples mit Locality (`labelloc`) und
Messtischblatt (`mtb`); pro Fieldtrip zusätzlich Sonnen-/Mondzeiten und
Mond-Sichtbarkeitsfenster (siehe `PROJECT_PLAN.md` §6.5).

Akzeptanzkriterium: Sample zeigt nach < 2 s den Ortsstring und MTB.
Fieldtrip zeigt Sonnenauf-/-untergang und Mondphase; für eine
Test-Nachtexkursion ist `moon_above_horizon_during_fieldtrip` gegen
eine externe Referenz verifiziert.

### 2a – Geocoding & MTB-Anreicherung (done am 2026-05-10)

- [x] Migration `1700000002_phase2_enrichment_fields.go`:
      `admin_units`, `mtb`, `astro` (json) auf `samples`/`fieldtrips`,
      neue `geocache`-Collection mit unique index (service, key)
- [x] `internal/services/labelloc.go` mit defensivem UTF-8-Handling
      (`repairDoubleEncodedUTF8`: erkennt 4-Byte-Mojibake `0xC3 0x83
      0xC2 0xXX` und korrigiert auf `0xC3 0xXX`; Tests grün)
- [x] `internal/services/mtb.go` (außerhalb DE: `found:false`,
      kein Fehler — verifiziert mit La Palma)
- [x] `internal/services/geocache.go`: 7-Tage-Cache mit
      `CoordinateKey(lat, lon, lang)` (5 Nachkommastellen ≈ 1.1m)
- [x] HTTP-Wrapper mit exponential backoff, kein Retry auf 4xx
- [x] `internal/enrichment/`: After-Sample-Insert-Hook in Goroutine
      mit Recover, parallele labelloc + MTB-Calls
- [x] Fieldtrip-Name-Promotion: wenn Fieldtrip noch Default-Namen hat,
      auf "Würzburg — 2026-05-10" upgraden sobald Locality bekannt
- [x] Verifiziert: 2. Sample mit gleichen Koordinaten → Cache-Hit
      (~25 ms statt ~1.5s), `mtb_found:false` für Kanaren

### 2b – Astro (done am 2026-05-10)

- [x] `internal/astro/sun.go`: NOAA-Solarposition →
      `ComputeSunTimes(date, lat, lon)` mit Sonnenauf-/-untergang +
      civil twilight. Verifiziert für Würzburg 2026-05-10 ±5min vs.
      timeanddate.com.
- [x] `internal/astro/moon.go`: Meeus simplifiziert → `MoonPhase`,
      `MoonIllumination`, `MoonPhaseName`, `MoonAltitude`,
      `MoonAboveHorizonDuring`, `MaxMoonAltitudeDuring`,
      `ScanMoonRiseSet`. Verifiziert mit bekannten Neumond-/Vollmond-
      Daten 2026-04-17 / 2026-05-01.
- [x] `internal/astro/astro.go`: `ComputeFieldtripAstro` als
      JSON-bereiter Wrapper.
- [x] Tests grün, Coverage 78.3%.
- [x] Library-Entscheidung dokumentiert: `docs/adr/0001-astro-eigenbau.md`.
- [x] Fieldtrip-Astro-Recompute in `internal/enrichment/fieldtrip.go`,
      sequenziell nach Sample-Anreicherung. Centroid wird inkrementell
      neu berechnet (Mean aller Samples).
- [x] Bug-Fix nebenbei: `fieldtripFromRecord` konvertiert PB-UTC-Zeiten
      auf Berlin TZ, damit `SpansMidnight` (und damit
      `night_fieldtrip`) Mitternachtsübergänge korrekt erkennt.

End-to-end-Smoke-Test verifiziert (Würzburg 2026-05-10 Tag-Fieldtrip):
- Sonnenaufgang 05:42, Sonnenuntergang 20:51 (Referenz 05:46 / 20:48)
- Mondphase 0.79 → "abnehmender Sichelmond", 38.7% Beleuchtung
- Mondaufgang 03:01, Mondsichtbarkeit max. 5.1° → niedrig stehend
- 2026-05-01 Nacht-Fieldtrip: Vollmond 99.7% Beleuchtung, max
  Altitude 19.3°, `night_fieldtrip=true` korrekt

### 2c – iOS-Anzeige der angereicherten Daten (done am 2026-05-10)

- [x] `Core/Models/`: `Sample`, `Fieldtrip`, `Astro`, `AdminUnits`,
      `MTB` als Decodable-Structs. `try?` für JSON-Felder, weil PB für
      ungesetzte JSON-Felder `""` statt `null` zurückgibt.
- [x] `Core/Models/Decoder.swift`: `JSONDecoder.fieldworks` mit
      Custom-DateStrategy, die sowohl PB-Format
      (`"yyyy-MM-dd HH:mm:ss.SSS'Z'"`) als auch ISO-8601-mit-Offset
      (Astro-Felder) parst.
- [x] `Core/PocketBaseClient/SampleClient.swift`: `createSample` +
      `fetchSample(id:)`, beide auf `Sample` zurückgebend.
- [x] `Core/PocketBaseClient/FieldtripClient.swift`:
      `listRecent(limit:)`, `fetch(id:)`.
- [x] `AddSampleViewModel`: nach erfolgreichem POST 10×1.5 s polling
      auf `fetchSample(id:)` bis Locality oder MTB da, dann Banner
      umschaltet auf "fertig".
- [x] `AddSampleView`: Success-Card zeigt Code (groß, monospace) +
      Locality + Country + MTB-Sheet, mit Inline-Spinner solange
      Anreicherung pending.
- [x] `FieldtripsListView` / `FieldtripsListViewModel`: Tab
      "Exkursionen", lädt jüngste 50, Pull-to-Refresh, Sortierung
      `-collecting_day,-started_at`. Zeile zeigt Name, Tag, Locality,
      MTB-Nr., Mond-Icon bei `night_fieldtrip=true`.
- [x] `FieldtripDetailView` mit Header (Tag, Zeitfenster, Locality,
      MTB, Centroid) + `AstroPanel`-Komponente.
- [x] `AstroPanel`: drei Sektionen (Sonne mit Auf-/Untergang +
      bürgerliche Dämmerung; Mond mit Phase, Beleuchtung %, Auf-/Untergang;
      Während-der-Fieldtrip mit "Mond war anwesend" + max. Höhe und
      einer einordnenden Zeile wie "niedrig stehend"/"hochstehend —
      Lichtfang erschwert").

End-to-end im iOS-Simulator (iPhone 16 Pro, iOS 26.2 Sim):
- App installiert und gestartet → AddSample rendert mit GPS-Card.
- GPS-Permission gewährt, Würzburg-Koordinate gesetzt → GPS-Card
  zeigt 49.791300, 9.953400 ±5 m.
- Backend-End-to-end (curl-getrieben, da kein Touch-Automation in
  diesem Setup): Liste zeigt Fieldtrips korrekt sortiert, Detail-View
  rendert Astro-Panel mit allen Werten.

Phase-2-Limitierungen (bewusst späteren Phasen vorbehalten):
- Polling statt PocketBase-Realtime-Subscription für Enrichment.
  Realtime kommt mit dem Sync-Layer in Phase 3.
- iOS-Mirror der Astro-Mathematik fehlt (Pre-Trip-Vorschau "Mond
  steht heute Nacht hoch"). Erst wenn das Bedürfnis konkret wird —
  siehe ADR 0001 Konsequenzen.

---

## Phase 3 – Offline-First

**Status: done** — alle drei Chunks geliefert.

Ziel: iOS arbeitet im Funkloch genauso schnell wie online, syncht im
Hintergrund.

Akzeptanzkriterium: Flugmodus → 10 Samples anlegen → Internet wieder da
→ alles im Backend, Codes konsistent, Reverse-Geocoding nachgepflegt.

### 3a – Local DB + lokale Code-Vergabe (done am 2026-05-11)

- [x] GRDB 6.29+ als SPM-Dep im `ios/project.yml`
- [x] FieldworksdiaryTests-Target in xcodegen mit `GENERATE_INFOPLIST_FILE=YES`
- [x] `Core/Geo/Codes/Codes.swift`: Swift-Port von `internal/codes`
      (`collectingDay`, `formatCode`, `collectingDayKey`)
- [x] `FieldworksdiaryTests/CodesTests.swift`: 9 Test-Cases parallel zu den
      Go-Tests (Cutoff-Edges, Format, Jahreswechsel) — 9/9 grün
- [x] `Core/Persistence/Database.swift`: GRDB-DatabasePool,
      Migration `v1_local_samples_and_sequences`, Test-Init
      (in-memory + path)
- [x] `Core/Persistence/LocalSample.swift`: GRDB-Codable-Model mit
      Sync-Status-Feldern
- [x] `Core/Persistence/LocalSampleStore.swift`: `createLocal()` mit
      atomarer Sequenz-Allokation, `fetchAll`/`fetchById`/`fetchPending`,
      `observeAll()` als AsyncSequence
- [x] `Core/Sync/SyncRunner.swift`: kick()-basierter Background-Push
      mit Goroutine-äquivalentem Task, pollt Backend nach Sync für
      Enrichment
- [x] `App/AppContainer.swift`: DI-Container, hält DB+Store+Sync
- [x] AddSampleView/ViewModel: lokales Schreiben zuerst, zeigt
      Code sofort, Sync-Status-Badge (pending / syncing / synced /
      failed), Server-Code-Anzeige falls abweichend, Retry-Knopf

End-to-end (Build + Test grün): `xcodebuild ... test` → 9/9 Tests grün.

Phase-3a-Limitierungen, die in 3b folgen:
- Backend ignoriert weiterhin den Client-Code und vergibt seinen eigenen
  → bei einem Round-Trip ändert sich der Code auf dem Bildschirm. In 3b
  lernt der Hook, den Client-Code zu respektieren, solange er
  konfliktfrei ist; bei Konflikt wird der Originalcode in
  `original_code` gesichert.
- Kein Listen-Reload-Mechanismus für FieldtripsList aus lokaler DB —
  noch reine Backend-Reads.

### 3b – Sync-Push + Konfliktauflösung (done am 2026-05-11)

- [x] `internal/codes/ParseSequence(code)`: pure Hilfsfunktion, 9
      Test-Cases inkl. Edge-Cases (`/0`, `/abc`, leerer String,
      mehrere Slashes).
- [x] Backend-Hook `processSample` honoriert eingehenden `code`:
      kein Konflikt → übernehmen + `ensureSequenceAtLeast(N)`;
      Konflikt → `nextSequence` allokieren + `original_code` setzen.
- [x] Migration `1700000003_drop_unique_index_samples_code`: ändert
      `idx_samples_code` von UNIQUE auf normal, damit PocketBase
      nicht **vor** dem Hook auf `validation_not_unique` abbricht.
      Eindeutigkeit wird jetzt im Hook in der RunInTransaction
      durchgesetzt (single-device-safe via SQLite-Write-Serialisierung).
- [x] iOS `Sample.originalCode`-Feld; `SampleClient.createSample` mit
      optionalem `code`/`clientUuid`/`clientUpdatedAt`.
- [x] iOS `SyncRunner` sendet jetzt `code`, `client_uuid`,
      `client_updated_at`; bei Server-Reassign wird `backendCode`
      gespeichert und `originalCode` aus der Server-Antwort übernommen.
- [x] SyncRunner: 30-s-Retry-Timer für `.pending`/`.failed`-Rows,
      zusätzlich zu kick().
- [x] Postman-Collection: 4 neue Cases in Folder "Phase 3b — Client-
      Code-Honoring". Newman verifiziert: 24/24 Assertions, 17/17
      Requests grün (delay 2s).
- [x] `tests/api.http`: gleicher Satz Cases als REST-Client-Form.

Smoke-Test-Reihenfolge auf einem frischen Backend:
| # | Request | Erwartung |
|---|---|---|
| 1 | code=260520/1, frisch | code=260520/1, original_code leer |
| 2 | code=260520/1, doppelt | code=260520/2, original_code=260520/1 |
| 3 | code=260520/7 (Sprung) | code=260520/7, Sequenz hochgezogen |
| 4 | ohne code | code=260520/8 (max+1) |
| 5 | code=260520/7, jetzt belegt | code=260520/9, original_code=260520/7 |

Bewusst nicht in 3b umgesetzt (in 3c oder später):
- Echte Idempotenz via `client_uuid` (zweite POST mit selbem UUID
  würde aktuell ein zweites Sample erzeugen). Risiko ist gering, weil
  unser SyncRunner gegen einen einzelnen `.synced`-Status pusht.
- Exponential Backoff statt fixem 30-s-Interval. Reicht für die
  Single-User-Charakteristik.

### 3c – Sync-Pull + Karten-Fallback (done am 2026-05-11)

- [x] Migration `v2_local_fieldtrips`: neue Tabelle mit ID/Name/Day/
      Night/Started/Ended/Centroid + JSON-Blobs für `admin_units`,
      `mtb`, `astro` (Sub-Objekte als JSON statt vieler Spalten,
      damit derselbe Decoder wie auf dem Netzwerk-Pfad zieht).
- [x] `AdminUnits`/`MTB`/`Astro` von Decodable auf Codable
      hochgezogen, damit sie als JSON wieder rausgeschrieben werden.
- [x] `Core/Persistence/LocalFieldtrip.swift`: GRDB-Record + typed
      Accessoren `adminUnits`/`mtb`/`astro` die das JSON on-demand
      decoden, plus `init(from: Fieldtrip)`-Konstruktor.
- [x] `Core/Persistence/LocalFieldtripStore.swift`: `upsert([Fieldtrip])`,
      `fetchAll`/`fetchById`, `observeAll()` als AsyncSequence über
      `ValueObservation`.
- [x] `Core/Sync/FieldtripsHydrator.swift`: `pull(limit:)` für die
      Liste, `pullOne(id)` für gezieltes Nachholen.
- [x] `SyncRunner`-Callback `onSampleSynced(excID)`: nach Sample-Sync
      wird die Fieldtrip gezielt nachgepullt — damit landen
      Astro/Enrichment ohne Listen-Refresh in der lokalen DB.
- [x] `FieldtripsListViewModel` refactor: observiert die lokale DB,
      pullt initial in `start()`, Pull-to-Refresh kickt erneut.
      `FieldtripsListView` zeigt jetzt LocalFieldtrip-Daten.
- [x] `FieldtripDetailView` refactor: nimmt nur die ID, liest lokal
      und pullt im Hintergrund. Funktioniert ohne Internet, solange
      die Fieldtrip zuvor synchronisiert wurde.
- [x] `Features/AddSample/CoordinatePickerView.swift`: SwiftUI-
      `MapReader` + `Map(position:)` + Tap-Gesture zum Pin-Setzen.
      Zeigt den aktuellen GPS-Fix als Referenz-Annotation an, plus
      Live-Koordinaten-Readout.
- [x] `AddSampleView`: neuer Button "Koordinate manuell setzen"
      öffnet Picker als Sheet; bei gesetzter Koordinate wird sie
      statt GPS verwendet, "Probe anlegen" auch ohne GPS-Fix
      möglich.
- [x] `AddSampleViewModel.submit(overrideCoordinate:)` nimmt den
      manuellen Punkt; accuracy/altitude werden in dem Fall bewusst
      nicht gesetzt (unbekannt).

End-to-end (iPhone 14 Pro, iOS 26.2 Sim, am 2026-05-11):
- App startet, 4-Tab-Bar mit Neu / Exkursionen / Status / Einstellungen.
- AddSample zeigt GPS (Würzburg 49.79/9.95 ±5 m), Probe-Anlegen,
  Koordinate-manuell-setzen — Build+Test grün, Screenshot verifiziert.

Bewusst NICHT in 3c umgesetzt (kommt wenn das Bedürfnis konkret ist):
- PocketBase-Realtime-SSE-Subscription. Pull-on-foreground +
  Pull-to-refresh + onSampleSynced-Trigger reichen für den Single-
  User-Pattern; Realtime würde primär Multi-Device helfen.
- Tile-Caching der Karte für Offline-Map-Anzeige (Phase 3-Spec §7.1).
  Erst wenn jemand wirklich im Funkloch eine Karte braucht.

---

## Phase 4 – Fundort-Verwaltung und Vorschläge

**Status: done** (am 2026-05-11). Astro-Panel war schon mit Phase 2c
geliefert; in Phase 4 kommt Locality-CRUD + Auto-Vorschlag dazu.

Ziel: Manuelle Fundorte; Auto-Vorschlag für Fieldtrip → Locality;
Fieldtrip-Detail-Ansicht mit Astro-Panel.

Akzeptanzkriterium: Mehrere Exkursionen werden korrekt einem Fundort
zugeordnet; manuelle Korrektur möglich. Fieldtrip-Detail zeigt für den
Sammeltag Sonnenaufgang, Sonnenuntergang, Mondphase und (bei
Nachtexkursionen) den Mond-Sichtbarkeitsstatus.

### 4a – Localities CRUD (done am 2026-05-11)

- [x] `Core/Models/Locality.swift` Decodable mit "0 → nil"-Mapping
      für die Number-Felder, die PB als 0 zurückliefert.
- [x] `Core/PocketBaseClient/LocalityClient.swift` mit
      `listAll`/`fetch`/`create`/`update`.
- [x] Migration `v3_local_localities` + `LocalLocality`-GRDB-Record
      + `LocalLocalityStore` (upsert/fetch/observe).
- [x] `Core/Sync/LocalitiesHydrator.swift`: Pull-on-launch +
      Pull-to-refresh. Writes gehen direkt über HTTP (Locality-
      Pflege ist kein Feld-Workflow, kein Offline-Outbox nötig).
- [x] Neuer Tab "Fundorte" mit `LocalitiesListView` (lokales Read,
      Pull-to-refresh) und Plus-Knopf für `LocalityEditView`.
- [x] `LocalityEditView` als Create-und-Edit-Formular: Name,
      `CoordinatePickerView`-Sheet für die Centroid-Auswahl,
      Radius-Slider (25 m – 5000 m), Notizen.
- [x] `LocalityDetailView` mit "Bearbeiten"-Knopf.

### 4b – Auto-Suggestion + Accept-UI (done am 2026-05-11)

- [x] `internal/grouping/distance.go`: pure `HaversineMeters` und
      `NearestLocalityWithin`. Tests 95 % Coverage, inkl.
      Property-Cases (Same Point, Würzburg-Frankfurt ~97.6 km,
      Grad-pro-Distanz an 50 °N, Grad Latitude überall).
- [x] Migration `1700000004_phase4b_suggested_locality`: neues
      Relations-Feld `suggested_locality` auf `fieldtrips`.
- [x] `internal/enrichment/fieldtrip.go` setzt nach Astro-Recompute
      die `suggested_locality`, **nur wenn `locality` leer ist** —
      manuelle Zuordnungen werden nie überschrieben.
- [x] iOS `Fieldtrip` + `LocalFieldtrip` + Migration v4 mit den
      neuen Spalten `locality` und `suggested_locality`.
- [x] `FieldtripClient.setLocality(id, locality)`: PATCH-Endpoint.
- [x] `FieldtripDetailView` rendert drei Fälle:
      - Locality zugeordnet → grüne Card mit Name + "Zuordnung
        entfernen"-Knopf
      - Suggestion vorhanden (locality leer) → orange Lightbulb-Card
        "Diese Exkursion liegt vermutlich im Fundort X" + Zuordnen-
        und Später-Buttons
      - Nichts → kein Locality-Block sichtbar

End-to-end-Verifikation Backend (curl-Smoke-Test):
| # | Szenario | Ergebnis |
|---|---|---|
| 1 | Fundort + Sample 200 m östlich (im Radius 1000 m) | `suggested_locality` gesetzt |
| 2 | Sample 5 km entfernt vom einzigen Fundort | `suggested_locality` leer |
| 3 | Fieldtrip mit gesetztem `locality`, neues Sample triggert Recompute | `locality` bleibt, Suggestion wird **nicht** überschrieben |

### Bewusst nicht in Phase 4 umgesetzt

- DBSCAN-Cluster-Cron für räumliche Split-Vorschläge — kommt wenn
  Datenmenge groß genug wird, dass das sinnvoll ist.
- Locality-Löschung — geht aktuell nur über PocketBase-Admin. Add
  später als Detail-Toolbar-Aktion mit Confirmation.

---

## Phase 5 – Filter, Suche, Listen

**Status: done** — alle drei Chunks geliefert (5a Backend, 5b
iOS-Filter, 5c Karten-Ansicht).

Ziel: Zeitliche und geographische Filter über die Daten.

Akzeptanzkriterium: "Zeige alle Aufsammlungen 15.04.–15.05. über alle
Jahre auf den Kanaren" funktioniert.

### 5a – Backend-Denormalisierung (done am 2026-05-11)

- [x] Migration `1700000005_phase5_filter_columns`: neue Spalten
      `day_of_year` (int 1..366), `country` (text), `admin_area` (text)
      auf `fieldtrips`, plus Indizes für jede einzeln.
- [x] `internal/enrichment/fieldtrip.go` setzt nach jeder
      Recompute-Runde alle drei Felder. `day_of_year` aus
      `time.YearDay()` der parsed `collecting_day`; `country`/
      `admin_area` aus `admin_units` via neuer Hilfsfunktion
      `decodeAdminUnits`.
- [x] PB-Filter-Query getestet mit drei Szenarien:
      `day_of_year >= 105 && day_of_year <= 141` (April–Mai), nur
      `country='Deutschland'`, und das Akzeptanzkriterium kombiniert
      (`day_of_year >= 105 && day_of_year <= 135 && country='Spanien'`
      ⇒ exakt ein Treffer: La Palma 2025-04-25).
- [x] Postman + api.http erweitert; Newman 26/26 grün.

Phase-5a-Limitierungen (in 5c oder später):
- `samples` selbst kriegen die Filter-Spalten NICHT; gefiltert wird
  ausschließlich auf Fieldtrip-Ebene. Sample-Listen sind Drill-down
  über die Fieldtrip.
- `island` / `island_group` als eigene Spalten habe ich weggelassen —
  die Kanaren-Frage löst `country='Spanien' && admin_area='Kanarische
  Inseln'`. Wenn wir später z. B. nach einer einzelnen Insel filtern
  wollen, kommt das als Phase-5c-Add.

### 5b – iOS-Filter-Sheet (done am 2026-05-12)

- [x] Migration v5 (`v5_fieldtrips_filter_columns`) auf der iOS-DB:
      Spalten `day_of_year`, `country`, `admin_area` auf
      `local_fieldtrips`, plus Indizes.
- [x] `Fieldtrip` + `LocalFieldtrip` um die drei Felder erweitert,
      `init(from: Fieldtrip)` kopiert sie.
- [x] `Features/Fieldtrips/FieldtripsFilter.swift`: Domain-Modell mit
      zwei orthogonalen Achsen — Datum (`.off` / `.absolute(from,to)` /
      `.seasonal(fromDOY,toDOY)`) und `country`. Saisonal mit Wrap
      (`fromDOY > toDOY` ⇒ Bereich überspannt Jahreswechsel).
- [x] `Features/Fieldtrips/FieldtripsFilterSheet.swift`: Sheet mit
      Segmented-Picker für den Datumsmodus, Date-Picker für absolut,
      Monat/Tag-Picker für saisonal, Country-Picker aus den lokal
      bekannten Werten. Anwenden / Zurücksetzen.
- [x] `FieldtripsListViewModel`: hält `all` (alle lokalen) und
      `visible` (gefiltert), rebuilded automatisch wenn Filter sich
      ändert oder neue Daten reinkommen.
- [x] `FieldtripsListView`: Filter-Knopf in Toolbar (Icon ist fett
      wenn Filter aktiv), Filter-Chip unter dem Header zeigt
      "n von m gefiltert" mit Aufheben-Button, separater Empty-State
      "Keine Treffer" wenn Filter alle ausschließt.
- [x] `FieldworksdiaryTests/FieldtripsFilterTests.swift`: 7 Test-Cases
      inkl. seasonal wrap und kombinierter Filter; alle grün.

End-to-end: iOS-Build + Test grün (16 Tests gesamt), Newman gegen
frisches Backend 26/26 grün. Akzeptanzkriterium der Phase erfüllt:
April-Mai-Bereich + Spanien liefert exakt die Kanaren-Fieldtrip.

### 5c – Karten-Ansicht aller Fundorte (done am 2026-05-12)

- [x] `Features/Localities/LocalitiesMapView.swift`: SwiftUI-`Map`
      mit `Marker` pro Fundort, `MapCircle`-Overlay zeigt jeweils
      den Radius als rote Tönung.
- [x] Camera-Fit auf das Bounding-Box der Pins mit 1.5× Padding,
      Mindest-Span 0.01° (sonst „Straßenansicht" bei einem einzigen
      Pin).
- [x] Pin-Auswahl via `Map(selection:)` → `navigationDestination`
      pusht `LocalityDetailView` der gewählten Locality. Selection
      wird nach 0.4 s zurückgesetzt damit derselbe Pin nach Detail-
      Rückkehr erneut tappbar ist.
- [x] `MapUserLocationButton` + `MapCompass` als Standard-Controls.
- [x] Empty-Overlay wenn lokal noch keine Fundorte vorhanden.
- [x] Toolbar-Knopf "Karte" links in `LocalitiesListView`, navigiert
      über die bestehende NavigationStack auf den Map-View.

Bewusst weggelassen:
- Fieldtrip-Centroids als zweite Pin-Farbe. Lass ich für später —
  die Map-Pins für Localities sind schon ausreichend für den
  „Wo waren wir schon?"-Use-Case.
- Heatmap. Erst sinnvoll wenn die Datenmenge groß genug ist.

---

## Phase 6 – Determinationen und Personen

**Status: done** (am 2026-05-12).

Ziel: Mehrere Determinationen pro Sample mit `det.`/`t.`/`vid.`.

Akzeptanzkriterium: Mehrere Determinationen pro Sample, korrekte
Anzeige in Listen.

### Backend

- [x] Migration `1700000006_phase6_people_determinations`:
      - `people` (full_name, abbreviation, email, notes)
      - `determinations` (sample-Relation mit CascadeDelete,
        species_text, kind als Select det/t/vid, optionale
        person-Relation, determined_on, notes, client_uuid)
- [x] Indizes auf `people.full_name`, `determinations.sample`,
      `.kind`, `.person`.
- [x] PB-Select-Feld validiert kind ⇒ `bogus` wird mit HTTP 400 +
      `validation_invalid_value` abgelehnt.

### iOS

- [x] `Core/Models/Person.swift`, `Determination.swift` mit
      `DeterminationKind`-enum (det/t/vid) inkl. labelShort/labelLong.
- [x] `PersonClient` (list, create), `DeterminationClient`
      (list-by-sample, create, update, delete).
- [x] `LocalSampleStore.fetchByFieldtrip(_:)` für Drill-down von der
      Fieldtrip in die Proben-Liste.
- [x] `Features/Samples/SampleDetailView.swift`: Code, Metadaten,
      "Bestimmungen"-Section mit Liste pro Sample, Tap → Edit,
      "+ Neu"-Button (gesperrt solange Sample noch nicht gesynct ist).
- [x] `DeterminationEditView`: TextField für species, inline Picker
      mit det./t./vid. + lateinischer Glosse, Person-Button öffnet
      `PersonPickerView`, DatePicker, Notizen, Löschen mit
      Confirmation-Dialog.
- [x] `PersonPickerView`: Searchable-Liste mit "Neue Person
      anlegen"-Row, der `NewPersonSheet` öffnet und die frische
      Person direkt zurückgibt.
- [x] `FieldtripDetailView` zeigt jetzt eine "Proben"-Section mit
      Drill-down auf `SampleDetailView`. Pending-Sync-Indikator pro
      Zeile.

### Verifikation

- iOS-Tests: 16/16 grün (keine neuen Tests in dieser Phase, weil
  die Logik fast komplett UI ist).
- Postman/Newman: **34/34 Assertions, 25/25 Requests** gegen frisches
  Backend. Neue Folder "6 Phase 6 — Personen und Bestimmungen" mit:
  Person POST, Sample POST, det.-Determination, vid.-Determination,
  ungültiges kind ⇒ 400, GET liste filtert sauber nach sample.

### Bewusst nicht in Phase 6

- **Offline-Outbox für Determinationen/Personen** — Determinationen
  werden am Schreibtisch gemacht, nicht im Feld. Online-only-Writes
  reichen.
- **People-Liste als eigener Tab** — der Picker reicht für den
  aktuellen Workflow. Eigene Verwaltungsansicht wenn die Datenmenge
  rechtfertigt.
- **Default = aktueller User** — kommt zusammen mit Auth in einer
  späteren Phase. Bis dahin wählt der User die Person explizit.
- **`linked_user`-Feld auf people** — bewusst weggelassen, weil wir
  noch kein User-System haben. Kommt mit Auth.

---

## Phase 7 – Etiketten-PDFs

**Status: done am 2026-05-12.** 7a (Locality + A6) und 7b
(Determination + Multi-Up + Bisherige-PDFs-Liste) komplett.
Bewusst nicht geliefert: Reprint-Chain mit `superseded_by` (manuelle
Korrektur per PocketBase-Admin reicht für jetzt) und iOS-Multi-Select-
UI (es wird automatisch über alle gesyncten Proben gerendert).

Ziel: A6-PDF-Bögen mit Locality- und Determinationsetiketten.

Akzeptanzkriterium: A6-Bogen mit korrekten Etiketten, Korrektur und
Neudruck mit `superseded_by`-Verkettung möglich.

### 7a – Locality-Etiketten (done am 2026-05-12)

- [x] Migration `1700000007_phase7_label_pdfs`: `label_pdfs` mit
      `kind` (Select locality/determination), `pdf_file` (File,
      max 10 MB, application/pdf), `samples` (many-Relation),
      `template`, `generation_params` (json), `superseded_by`
      (Self-Relation für Reprint-Chain).
- [x] `internal/pdf/locality.go` rendert A6-Seiten mit
      `github.com/jung-kurt/gofpdf` (1.16.2). Body-Lines:
      `Land, Region` / `Locality` / `lat° N, lon° E, alt m` /
      `dd.MM.yyyy als entomologisches Datum (12.V.2026)` mit
      `leg. <abbreviation>` / `MTB <num> (<name>)`. Code rechts
      unten in 10 pt Courier-Bold.
- [x] Pure-Tests in `internal/pdf/locality_test.go`: bodyLines mit
      full/minimal Daten, entomologisches Datum (V/XII), PDF-Header-
      Validierung. 6/6 grün.
- [x] `internal/api/labels.go` mit Custom-Endpoint
      `POST /api/label-pdfs/locality`. Body: `{sample_ids: [...],
      template: "default"}`. Handler lädt Samples + zugehörige
      Fieldtrips (batched), mappt nach `pdf.SampleLabel`, rendert,
      legt `label_pdfs`-Record an über `forms.RecordUpsert` mit
      `filesystem.NewFileFromBytes` für das PDF.
- [x] iOS `LabelPDF`-Model, `LabelClient.generateLocality(...)` +
      `downloadPDF(label) → URL` in Cache-Verzeichnis.
- [x] `FieldtripDetailView` bekommt unter der Proben-Liste einen
      "Locality-Etiketten als PDF"-Button (nur aktiv solange
      mindestens ein gesynctes Sample existiert). Nach erfolgreichem
      Render öffnet sich `PDFShareSheet` mit QuickLook-Preview und
      System-`ShareLink` für AirDrop/Drucken/Speichern.
- [x] Postman/Newman: 3 neue Cases (POST locality, GET file,
      Empty-IDs ⇒ 400). Suite gesamt 28 Requests, **41/41
      Assertions grün**.
- [x] Echter PDF-Output verifiziert: Würzburg-Sample mit Höhe →
      A6, FPDF 1.7, 1.4 KB, `pdftotext` zeigt alle Felder inkl.
      `280 m` und `12.V.2026`-Format.

### 7b – Determination + Multi-Up + History (done am 2026-05-12)

- [x] Refactor `internal/pdf/` in einen gemeinsamen Layout-Layer:
      neue `layout.go` mit `Layout`-enum (`A6Single` / `MultiUpA4`),
      `CellStyle`-Preset-Paar (8pt/10pt für A6, 6pt/7pt für A4-Grid),
      generische `renderA6Single` / `renderMultiUpA4`-Helpers, die
      eine Per-Label-`draw(i, pdf, x, y, w, h, tr)`-Closure
      bekommen.
- [x] `internal/pdf/determination.go` mit `DeterminationLabel`
      (Code, SpeciesText, Kind, PersonAbbrev, DeterminedOn) und
      `RenderDeterminationLabels(layout)`. Species in Italic,
      kind+person+date in Body-Font, Code rechts unten wie bei
      Locality.
- [x] `internal/pdf/locality.go` refactored auf den gemeinsamen
      Layer; bestehende Tests grün geblieben.
- [x] Multi-Up-A4-Layout: 4 × 8 Grid, 32 Etiketten pro A4-Seite,
      Auto-Pagebreak. Cell-Border in hellgrau zum Schneiden.
- [x] Endpoint `POST /api/label-pdfs/determination` analog zum
      Locality-Endpoint. Picks per Sample die jüngste `det.`, sonst
      die jüngste Determination jeglicher Art (sort
      `-determined_on,-created` mit `FindRecordsByFilter`).
      Samples ohne Determination werden übersprungen; sind ALLE
      Samples ohne Det. → HTTP 400 mit "(skipped N)"-Meldung.
- [x] Beide Endpoints respektieren `template`-Param und schreiben
      ihn auf den `label_pdfs`-Record.
- [x] 4 neue PDF-Unit-Tests (Multi-Up-A4 mit > 32 Labels → mehrere
      Seiten, Determination-Render, Detail-Lines-Format, shortKind-
      Mapping). 10/10 grün im `internal/pdf`-Paket.
- [x] iOS `LabelTemplate`-enum (`defaultA6` / `multiUpA4`).
- [x] `LabelClient.generateDetermination(...)` +
      `listForSamples(_:)` mit OR-joined `samples ?= 'id'`-Filter.
- [x] `FieldtripDetailView` zeigt jetzt:
      - Segmented-Picker A6 / A4 multi-up
      - Zwei Buttons "Locality" und "Determination"
      - "Bisherige PDFs"-Section unter den Buttons, mit Tap zum
        Wieder-Öffnen über QuickLook.
- [x] Postman: 3 neue Cases (locality multi-up, determination
      happy-path, determination ohne Det. → 400). Newman gesamt
      **46/46 Assertions, 31/31 Requests** grün.
- [x] Echte PDF-Outputs verifiziert via `pdftotext`: Locality A6
      und A4 multi-up rendern, Determination zeigt
      "Otiorhynchus ligustici / det. J. Brunner / 12.V.2026 /
      260512/1" wie erwartet.

### Bewusst nicht in Phase 7

- **Reprint-Chain** (`superseded_by`-Feld setzen bei
  korrigiertem Re-Render). Manuelle Korrektur per PocketBase-Admin
  reicht, solange die Datenmenge übersichtlich ist.
- **Multi-Select-UI in FieldtripDetail** für teilweises Drucken.
  Aktuell wird automatisch über alle gesyncten Proben der Fieldtrip
  gerendert. Multi-Select kommt zusammen mit einer Cross-Fieldtrip-
  Batch-Ansicht ("alle 2026er Würzburg-Proben") wenn das Bedürfnis
  da ist.
- **Konfigurierbare Templates** (Locality-String-Reihenfolge,
  Schriftgrößen etc.) — heute hardcoded auf den klassischen
  entomologischen Stil.

---

## Phase 8 – Genehmigungen

**Status: done** (am 2026-05-12).

Ziel: Permit-Verwaltung pro Fieldtrip.

### Backend

- [x] Migration `1700000008_phase8_fieldtrip_permits`: neue Felder
      `permit_number` (text) und `permit_pdf` (single file, nur
      `application/pdf`, max 20 MiB) auf `fieldtrips`.
- [x] `internal/pdf/locality.go`: `SampleLabel` um `PermitNumber`
      erweitert, `bodyLines` hängt eine Zeile `"Genehmigung <nr>"` an
      wenn nicht leer.
- [x] `internal/api/labels.go`: `sampleToLabel` liest
      `fieldtrip.permit_number` und reicht es ans Label durch.
- [x] PDF-Unit-Test erweitert um die Permit-Zeile, alle 10 PDF-Tests
      grün.

### iOS

- [x] `Fieldtrip` + `LocalFieldtrip` um `permitNumber` und
      `permitPDFFile` erweitert; Migration v6 fügt die Spalten lokal
      hinzu.
- [x] `FieldtripClient` bekommt drei neue Methoden:
      - `setPermitNumber(id, number)` — reines JSON-PATCH
      - `uploadPermitPDF(id, fileURL, permitNumber)` — Multipart-PATCH
        mit handgeschriebenem `Data`-Extension-Helper für Field und
        File
      - `clearPermitPDF(id, clearNumber)` — JSON-PATCH mit leerem
        `permit_pdf` (PocketBase-Konvention).
- [x] `PermitEditSheet`: Sheet mit Nummer-TextField,
      `fileImporter(.pdf)` für den Upload-Picker, Löschen-Knopf für
      ein vorhandenes PDF, "Speichern" wählt automatisch die richtige
      API (PDF-Upload vs reines Number-PATCH vs Clear).
- [x] `PermitEditSheet` kopiert die ausgewählte PDF aus dem
      Document-Picker in das eigene Caches-Verzeichnis, damit der
      Security-Scope nicht offen bleiben muss.
- [x] `FieldtripDetailView` zeigt jetzt eine **"Genehmigung"-Section**
      direkt unter dem Locality-Block: Nummer (oder Hinweis "keine"),
      Link auf das gespeicherte PDF (lädt in Caches und öffnet via
      `PDFShareSheet` mit QuickLook), Bearbeiten-Knopf.

### Verifikation

- Backend Smoke-Test gegen `/tmp/p8-permit.pdf`: `pdftotext` zeigt
  am Ende der Body-Lines `Genehmigung BV-2026/123` ✓
- Multipart-Upload via curl `-F` verifiziert; Response trägt
  `permit_pdf` als generierten Dateinamen ✓
- iOS-Tests: 16/16 grün, Build clean.
- **Newman: 49/49 Assertions, 34/34 Requests** grün gegen frisches
  Backend. Neuer Folder "8 Phase 8 — Genehmigungen" mit drei Cases
  (Permit setzen, Label mit Permit rendern, Permit löschen).

### Bewusst nicht in Phase 8

- **Mehrere Permits pro Fieldtrip** (z. B. Bundesland + Naturschutz).
  Heute nur eine Nummer + ein PDF. Kommt mit echten Anforderungen.
- **Permit-Validität / Ablauf-Datum** als eigenes Feld. Lass ich
  weg bis konkret gebraucht.
- **Permit-Ablauf-Warnung in der App** vor einer neuen Probe. Eine
  saubere Idee für später.

---

## Phase 9 – FloraIncognita-Integration

**Status: zurückgestellt** (am 2026-05-12 vom User explizit
übersprungen). Datenmodell-Felder dafür sind schon angelegt
(`Fieldtrip.plants` als json, `Sample.host_plant` als text), die
API-Integration kommt zurück sobald sie wirklich gebraucht wird.

Aufgaben (wenn aktiviert):
- [ ] API-Recherche
- [ ] Plant-Photos als Asset bei Fieldtrip oder Locality
- [ ] Verknüpfung Plant-Bestimmung ↔ Fieldtrip ↔ `Sample.host_plant`

---

## Phase 10 – Politur und App-Store-Vorbereitung

**Status: done am 2026-05-13.** TestFlight-Setup + Datenschutzerklärung
sind bereits in 11d geliefert worden; in dieser Phase ist die
Backup/Export-Funktion dazugekommen.

Aufgaben:
- [x] TestFlight-Build (Checklist in `docs/app-store-prep.md` — Code
      ist soweit, externe Apple-Dev-Schritte beim User)
- [x] Datenschutzerklärung (`docs/datenschutz.md`)
- [x] Backup/Export-Funktion:
      - Backend: `GET /api/export` (auth-required) liefert ein ZIP
        mit `data.json` (alle Owner-Records aus 6 Collections plus
        `meta.user`) und allen angehängten PDFs unter
        `pdfs/fieldtrips/...` und `pdfs/labels/...`. Datei-Reads
        gehen über `app.NewFilesystem()` + `GetFile(BaseFilesPath)`.
      - iOS: `ExportClient.downloadExport()` (URLSession-Download in
        Temp-Datei, parst `Content-Disposition` für den Dateinamen),
        Settings-Section „Daten" mit Idle / Downloading / Ready
        (`ShareLink`) / Failed-States.
      - AccountDeletionView verweist auf den Export im „Vor dem
        Löschen"-Bereich.

**Bewusst nicht** umgesetzt: Format-Version, Migrations-Felder, alles
was nach „Import-Format" riecht — der Export ist Backup-orientiert,
ein späterer Import-Pfad ist außerhalb des Scopes (siehe Memory).

---

## Phase 11 – Auth & Multi-User (App-Store-Ready)

**Status: 11a in progress (am 2026-05-12 gestartet).** Plan unter
`~/.claude/plans/die-app-soll-in-mellow-lantern.md` (vom User
genehmigt).

Ziel: Mehrere User mit eigenen Daten, plattform-übergreifende Auth
(iOS heute, Web/Android später), iOS-UX über Sign in with Apple +
E-Mail/Passwort.

Akzeptanzkriterium: Zwei verschiedene User können sich registrieren,
sehen jeweils nur ihre eigenen Daten, Geräte eines Users syncen
automatisch beim Login, Account kann gelöscht werden (App-Store-
Pflicht).

Designentscheidungen (mit User abgestimmt 2026-05-12):
- Auth-Methoden: Sign in with Apple + E-Mail/Passwort
- Daten-Scope: shared pool, `owner`-Relation, Rules filtern nach
  `owner = @request.auth.id` (additives Sharing möglich)
- Auth-Features: Account-Löschen + E-Mail-Verifizierung +
  Passwort-Reset, Test-Daten droppen

### 11a – Backend Auth Foundation (done am 2026-05-12)

- [x] Migration `1700000009_phase11a_drop_dev_data`: alle Records
      droppen für Clean-Slate
- [x] Migration `1700000010_phase11a_users_extended`: `_users` um
      display_name, abbreviation, day_cutoff_hour,
      default_fieldtrip_split_km, linked_person erweitert,
      AllowEmailAuth+AllowOAuth2Auth+RequireEmail+MinPasswordLength=8,
      User-Rules: ListRule nil (admin-only), ViewRule/Update/Delete
      `id = @request.auth.id`, CreateRule offen (self-service)
- [x] Migration `1700000011_phase11a_owner_columns_and_rules`:
      `owner` (relation → _users, CascadeDelete) auf allen sieben
      Tabellen; alte `user_id`-Text-Felder gedroppt;
      `idx_sample_sequences_owner_day` UNIQUE; user-facing
      Rules auf `@request.auth.id != '' && owner = @request.auth.id`
- [x] `internal/hooks/sample_create.go`: Auth-Record aus
      `apis.ContextAuthRecordKey` (nicht über RequestInfo, das ist
      auf Custom-Routes nicht befüllt), `defaultUserID` weg, alle
      Querys auf `owner` umgestellt
- [x] `main.go` registriert `RegisterOwnerSetters`: vor-Create-Hooks
      auf fieldtrips/localities/people/determinations, die `owner`
      vom Auth-Record setzen. Mismatch (client schickt fremde
      owner-ID) → 403
- [x] `internal/enrichment/fieldtrip.go`: `nearestLocalityID` filtert
      Locality-Kandidaten nach `owner = fieldtrip.owner`, damit User A
      keinen Vorschlag aus User Bs Fundorten kriegt
- [x] `internal/api/labels.go`: `RequireRecordAuth("users")` als
      Route-Middleware, plus `assertOwnerOnSamples` im Handler —
      DAO bypassed Rules, also explizit verifizieren
- [x] Postman-Collection: Pre-Request-Script registriert+loggt
      `newman@fieldworksdiary.local` ein, setzt `auth_token`,
      Collection-Level-`Authorization`-Header trägt es überall an
- [x] Verifiziert: zwei User-Curl-Test (eigene Codes /1, getrennte
      Fieldtrips, User B sieht User As Sample nicht). Newman gegen
      frisches Backend: **49/49 Assertions grün**.

Issue, das ich unterwegs gefunden und gefixt habe: `apis.RequestInfo(c).AuthRecord`
ist auf Custom-Routes **nicht** befüllt — `ContextRequestInfoKey` wird
nur in PocketBase's Collection-Handlern initialisiert. Auth-Record
liegt aber an `ContextAuthRecordKey` und wird von `LoadAuthContext`
(Pre-Middleware) für alle Routen befüllt. Beide Hook-Files lesen
jetzt direkt diesen Key.

### 11b – iOS Auth Foundation (done am 2026-05-13)

- [x] `Core/Auth/KeychainStore.swift` (SecItem-Wrapper, Service
      `org.fieldworksdiary.auth`, `kSecAttrAccessibleAfterFirstUnlock`)
- [x] `Core/Auth/AuthSession.swift` (`@MainActor ObservableObject`,
      `currentToken` als `nonisolated` damit HTTP-Clients ohne Hop auf
      MainActor lesen können)
- [x] `Core/Auth/AuthClient.swift` (Wrapper um `users/auth-with-password`,
      `auth-refresh`, `request-password-reset`, `auth-with-oauth2`,
      Account-Delete)
- [x] `Core/PocketBaseClient/PBAuth.swift` als minimaler `URLRequest`-
      Extension-Hook statt eines voll-ausgebauten `PBRequest`-Builders;
      jeder der 6 Clients (`SampleClient`, `FieldtripClient`,
      `PersonClient`, `LocalityClient`, `DeterminationClient`,
      `LabelClient`) kriegt im init eine optionale `AuthSession` und
      ruft `request.authenticate(with: auth)` vor dem URLSession-Call
- [x] `Core/Sync/SyncRunner`, `FieldtripsHydrator`, `LocalitiesHydrator`:
      neuer `authProvider`-Closure-Parameter, propagiert Token bei
      jedem Roundtrip
- [x] `AppContainer` hält `let auth: AuthSession`, `bootstrap()` ruft
      `auth.restoreOnLaunch()` (Refresh-on-Launch via Keychain-Token)
- [x] `WelcomeView`, `LoginView`, `RegisterView`, `PasswordResetView`
      (Apple-Sign-In-Button + `AccountDeletionView` bleiben für 11d)
- [x] `RootView` gated auf `auth.isSignedIn` → Welcome oder MainTabs
- [x] `SettingsView` mit Konto-Section (Email, Display-Name, Kürzel,
      Logout mit ConfirmationDialog); Account-Löschen kommt in 11d
- [x] `xcodebuild test`: 16/16 grün
- [x] App-Store-Sign-In-Capability + AppleSignInButton sind in 11d

Apple Sign In wurde absichtlich auf 11d verschoben, weil es das Apple-
Dev-Konsolen-Setup (Service ID, Private Key) braucht. E-Mail/Passwort
deckt den UX-Flow heute schon end-to-end.

### 11c – Multi-Device-Sync (done am 2026-05-13)

- [x] `Sample` um `accuracy_m`, `altitude_m`, `client_uuid`,
      `client_updated_at` erweitert; neuer `SampleListResponse`-Envelope
- [x] `SampleClient.listRecent(limit:)` (sort=`-collected_from`,
      Server filtert via Rule auf `owner = @request.auth.id`)
- [x] `Core/Sync/SamplesHydrator.swift` (Pull-Pendant zu Fieldtrips/
      Localities; single-flight via `isLoading`-Guard)
- [x] `LocalSampleStore.upsert([Sample])`:
      Match-Reihenfolge `client_uuid → backend_id`, in-flight
      Rows (`.pending`/`.syncing`) bleiben unangetastet, `local_sequences`
      wird auf den höchsten gesehenen Code/Tag bumped, damit Offline-
      Allokation nicht mit hydratisierten Codes kollidiert
- [x] `LocalSampleStore.reset()`, `LocalFieldtripStore.reset()`,
      `LocalLocalityStore.reset()` (truncate per `DELETE FROM` —
      löscht zusätzlich `local_sequences`)
- [x] `LocalSampleStore.userId` ist jetzt `var`, AppContainer schreibt
      ihn beim Login auf `auth.currentUser?.id`
- [x] `AppContainer.bootstrap()` abonniert `auth.$currentUser` per
      Combine:
      - Nutzer-Wechsel (oder Logout) → `wipeLocalStores()`
      - jeder Login (auch Restore-on-Launch) → parallel
        `samplesHydrator.pull()`, `hydrator.pull()`,
        `localitiesHydrator.pull()`
- [x] `xcodebuild test`: 16/16 grün

Designentscheidung: Pull bleibt opt-in pro Tab (`onAppear { pull }`);
der Login-Hook in AppContainer ist nur die *initiale* Drei-Wege-
Hydration, kein Konkurrenz-Mechanismus. Hydrators sind intern
single-flight, deswegen kann der Tab-Pull über den Container-Pull
laufen, ohne sich gegenseitig zu killen.

### 11d – App-Store-Pre-Flight (done am 2026-05-13)

- [x] `Features/Settings/AccountDeletionView.swift`: zweistufige
      Confirmation (Tippen von `DELETE`); ruft `auth.deleteAccount()`,
      Backend löscht via `CascadeDelete: true` auf der Owner-Relation
      alle abhängigen Records mit
- [x] `SettingsView` verlinkt die Account-Löschung im Konto-Bereich
- [x] `Features/Auth/AppleSignInButton.swift` mit
      `AuthenticationServices` (Token + AuthorizationCode an
      `AuthSession.signInWithApple`)
- [x] `WelcomeView` zeigt Apple-Button oben, dann Trenner, dann
      E-Mail-Flow
- [x] `ios/Fieldworksdiary/Fieldworksdiary.entitlements` mit
      `com.apple.developer.applesignin`
- [x] `ios/project.yml`: `CODE_SIGN_ENTITLEMENTS` gesetzt
- [x] `ios/Fieldworksdiary/PrivacyInfo.xcprivacy` (Email/Name/Precise
      Location als „linked, not tracking, App Functionality"; API-
      Reasons für UserDefaults/FileTimestamp/SystemBootTime/DiskSpace)
- [x] `docs/datenschutz.md` (DE, DSGVO-konform; Verantwortlicher-
      Block noch auszufüllen vor Submit)
- [x] `docs/app-store-prep.md` (Checklist von Apple-Dev-Account bis
      TestFlight-Upload — Code-Teil komplett, externe Schritte
      menschlich abzuarbeiten)
- [x] `docs/adr/0002-auth-and-owner-scoping.md` dokumentiert die
      shared-pool + owner-Filter-Entscheidung und das
      `ContextAuthRecordKey`-Detail
- [x] `xcodebuild test`: 16/16 grün; Bundle enthält
      `PrivacyInfo.xcprivacy`

**Postman-Auth-Token-Pre-Request** wurde bereits in 11a eingeführt
(49/49 Newman-Assertions grün), die Folder-„9 Auth"-Cases stehen mit
Auth-Setup, Register, Login, Multi-User-Isolation. Account-Delete-
Cascade-Verifikation per Newman steht noch aus — derzeit nur durch
DB-Inspektion verifiziert.

**Vor App-Store-Submit menschlich erforderlich:**

- Apple-Dev-Account, Bundle-ID-Registrierung, Service-ID + Private Key
  für Sign-in-with-Apple, Datenschutz-URL hosten, Marketing-Texte,
  Screenshots, TestFlight-Upload (siehe `docs/app-store-prep.md`).

---

## Phase 12 – Production-Härtung

**Status: pending**

Ziel: alle Hot-Pfade unter Test-Schutz, A11y-Audit ohne Kategorien-
Ausnahmen, keine forward-only-Migrationen mehr.

Akzeptanzkriterium: `bash scripts/check.sh` grün, AccessibilityAuditTest
läuft mit `.all` ohne `.subtracting(...)`, Coverage in den heute
ungetesteten Pfaden > 60 %.

Aufgaben:
- [ ] Tests für `Core/Sync/FieldtripsHydrator`, `LocalitiesHydrator`,
      `SamplesHydrator` (0 % → > 60 %)
- [ ] Tests für `Core/Auth/AuthSession` und `Core/Auth/AuthClient`
      (Token-Restore, Apple-Sign-In, Refresh-Pfad)
- [ ] Tests für `backend/internal/services/geocache.go`
      (48 % → > 80 %): Cache-Hit/Miss/TTL-Ablauf, SHA-256-Key-Stabilität
- [ ] Hydrator-Konsolidierung: gemeinsame Base oder Generic statt drei
      Quasi-Duplikate
- [ ] Farb-Tokens definieren (Light + Dark) und in der App durchziehen,
      damit `.contrast`-Audit wieder grün läuft
- [ ] AX-Layouts gegen größte Dynamic-Type-Stufe testen
      (`.dynamicType` + `.textClipped` im A11y-Audit reaktivieren)
- [ ] Down-Migrations für PocketBase (DB-Rollback bei Bad-Migration)
- [ ] Down-Migrations für GRDB (lokale-DB-Rollback)

---

## Phase 13 – Tile-Caching / Offline-Map

**Status: pending**

Ziel: Karten-Hintergrund offline verfügbar, sobald der User vorab ein
Gebiet markiert. Die Pin-Layer waren ab Phase 3 schon offline; nur die
Map-Tiles fehlten.

Akzeptanzkriterium: User wählt ein Rechteck auf der Karte → App lädt
die Tiles → Flugmodus an → die Map zeigt weiterhin den Hintergrund;
neue Samples lassen sich erfassen und auf der Karte sehen.

Aufgaben:
- [ ] Tile-Provider-Entscheidung (Apple-Maps-Cache vs. OSM-MBTiles vs.
      Swisstopo/IGN für DE/CH) — ADR schreiben
- [ ] Lokaler MBTiles-Store (SQLite mit Tile-Blobs)
- [ ] „Region herunterladen"-UI: Rechteck-Picker + Zoom-Range-Selector
      + Download-Fortschritt
- [ ] Cache-Größen-Limit + manuelles Aufräumen in Settings
- [ ] `LocalitiesMapView` + `CoordinatePickerView` nutzen Tile-Store
      automatisch, fallback auf Online-Tiles wenn Cache-Miss

---

## Phase 14 – UI-Redesign: Home-Dashboard + Sample-Foto

**Status: in progress** (gestartet 2026-05-20). Plan unter
`~/.claude/plans/wir-m-ssen-die-features-curious-lerdorf.md`.

Ziel: Den feldtauglichen Workflow der alten App in der neuen Architektur
nachbauen — grünes Home-Dashboard mit Active-Collector / Active-Fieldtrip
/ Recently-Sample und prominentem +-FAB ersetzt die 5-Tab-Bar als
Haupteinstieg. Sample-Erfassung um Notizen-Freitext und Foto-Aufnahme
(Kamera + Galerie) erweitert. Color-Tokens und A11y-Audit aus Phase 12
werden hier integriert.

Akzeptanzkriterium: Nach Login landet der User auf einem grünen
Home-Dashboard mit allen wichtigen Kontext-Infos und einem 64×64pt-FAB.
„Neue Probe" öffnet ein Sheet mit GPS, Notizen, Foto-Aufnahme; nach
Submit landet das Foto im PocketBase-`sample_photos`-Record. A11y-Audit
auf Home + AddSample läuft ohne `.subtracting(...)` durch, Dynamic Type
AX5 funktioniert ohne Clipping.

**Out of scope (Phase 14b/c folgt):** Marked Samples, Photos-Galerie,
Calendar-View, Sample-Map. Diese Menüpunkte kommen mit Placeholder-Stubs.

Aufgaben:
- [ ] Theme & Color-Tokens (`Assets.xcassets`, `AppColor`, `AppMetric`)
      — Brand-Grün light/dark, WCAG-AA verifiziert
- [ ] Backend: Migration `1700000012_phase14_sample_photos` (separate
      Collection mit owner-Rules, max 10 MB pro File)
- [ ] iOS GRDB-Migration v7 `local_photos`, `LocalPhoto`-Record +
      `LocalPhotoStore`
- [ ] `PhotoStorage` (Filesystem-Layer, JPEG-Kompression) +
      `PhotoPicker` (UIImagePickerController-Bridge)
- [ ] Home-Feature: `HomeView`, `HomeViewModel`, `HomeHeader`,
      `HomeMenuRow` (A11y-Pflichten gegen `.claude/rules/ACCESSIBILITY-IOS.md`)
- [ ] `SamplesListView` + `SampleDetailView` als top-level Liste
- [ ] `AddSampleView` erweitert um Notizen-`TextEditor` und Foto-Section
- [ ] `SyncRunner`: Photo-Upload nach erfolgreichem Sample-Push (multipart,
      idempotent via `client_uuid`)
- [ ] `RootView` → `HomeView` (statt MainTabs), `AppContainer` mit
      `PhotoStore`/`LocalPhotoStore`, Info.plist mit Camera/Photo-Usage
- [ ] Build + Tests grün, manueller Foto-Capture im Simulator verifiziert

---

## Phase O – Ortus-Ortsdaten am Sample

**Status: in progress** (gestartet 2026-11-09)

Ziel: labelloc/MTB-Reverse-Geocoding durch Ortus ersetzen; Ortsdaten
(Admin-Ebenen, Features, TK25-Quadrant) am Sample speichern.

- Spec: `docs/superpowers/specs/2026-11-09-ortus-sample-ort-design.md`
- Plan: `docs/superpowers/plans/2026-11-09-ortus-sample-ort.md`

Aufgaben:

Phase O1 – Backend — **done** (2026-11-09)
- [x] Task 0: Phasenstatus eintragen
- [x] Task 1: Label-Tabelle – Format, Generator, Go-Loader
- [x] Task 2: Label-Tabelle – Bereinigungsentwurf aller 77 Länder
- [x] Task 3: TK25-Quadrant (Go)
- [x] Task 4: Ortus-Wrapper
- [x] Task 5: Mapping Ortus → Place / SampleGeo / Features
- [x] Task 6: Migrationen – Placemarks, Samples, Sample-Features
- [x] Task 7: Placemark- und Feature-Store + Endpoints
- [x] Task 8: Sample-Anreicherung über Ortus
- [x] Task 9: Locality-Placemark über Ortus
- [x] Task 10: labelloc/MTB entfernen, Leser umstellen
- [x] Task 11: Phase O1 abschließen

Demo O1 (lokaler Ortus-Lauf, 2026-11-09):
- DE-Sample 49.681616/10.039652 → Ochsenfurt / Landkreis Würzburg /
  Unterfranken / Bayern / Deutschland, MTB 6326/1, GPS-Höhe bleibt
  erhalten.
- ES La Palma → Canarias / Santa Cruz de Tenerife, kein MTB.
- Nicht live verifiziert: DEM-Höhe und Inseln — der lokale Ortus hatte
  keinen DEM-/Insel-Layer (nur über Fixtures getestet).
- Label-Tabelle ist ein ungeprüfter Entwurf — Jo reviewt sie pro Land
  vor der O2-UI.

Phase O2 – iOS — **implementiert, wartet auf Test durch Jo** (gestartet 2026-11-09; App-Unit-Tests auf Tahoe nur via Xcode-IDE lauffähig, daher noch ungelaufen)
- [x] Task 12: Swift-Package `FieldworksGeo` – Label-Tabelle und TK25
- [x] Task 13: Swift – Ortus-Modelle, Mapping, Hash, Labels
- [x] Task 14: GRDB-Migration v13 und Stores
- [x] Task 15: Ortus-Client und Ortsauflösung beim Anlegen
- [x] Task 16: Sync – Placemark, Sample, Features
- [x] Task 17: UI – Ortsfelder anzeigen, bearbeiten, korrigieren, filtern
- [ ] Task 18: Phase O2 abschließen — offen: Jo führt `Cmd+Shift+U` + `bash scripts/test-ios-no-build.sh` aus und testet im Simulator; erst danach O2 done

Phase O3 – Backfill und Aufräumen
- [ ] Task 19: Backfill-Kommando
- [ ] Task 20: Alte Spalten entfernen
