# Projektplan: Käfer-Sammel-App (Arbeitstitel: `fieldworksdiary`)

Dieser Plan ist als Eingabe für `claude /init` gedacht. Er beschreibt Vision,
Architektur, Datenmodell und Implementierungsphasen so, dass Claude Code daraus
eine sinnvolle erste `CLAUDE.md` und Verzeichnisstruktur ableiten kann.

---

## 1. Vision & Scope

Eine mobile App (zunächst iOS, später ggf. Web/Android) zur Felderfassung von
Rüsselkäfer-Aufsammlungen. Sie ersetzt die bisherige App und löst zwei
strukturelle Probleme der Vorgängerlösung:

1. **Unübersichtliche „ohne Exkursion/Fundort"-Halde** – durch ein
   dreischichtiges Datenmodell (Aufsammlung → Exkursion → Fundort) und
   automatische Gruppierung ohne manuelle Abschluss-Aktion.
2. **Reibung im Feld** – durch konsequentes Offline-First (kein Internet,
   kein GPS) und automatische Vergabe der Aufsammlungs-Codes.

Spätere Ergänzungen (Etiketten-PDFs, Genehmigungen, FloraIncognita-Integration)
sind im Modell vorgesehen, werden aber phasenweise gebaut.

---

## 2. Architektonische Kernentscheidungen

### 2.1 Backend: PocketBase als Go-Library

- PocketBase wird **nicht** als Standalone-Binary genutzt, sondern als
  Go-Framework importiert. So lassen sich Hooks (Code-Vergabe, automatische
  Gruppierung, Reverse-Geocoding-Anreicherung, MTB-Anreicherung) direkt in Go
  schreiben und dort halten, wo sie hingehören.
- Backend läuft im **Docker-Container**. Dev-Setup mit `docker-compose`,
  Persistenz auf einem Volume (in Produktion: Docker-Maschine, später ggf. anderer
  Host).
- Endpoint ist in der iOS-App **konfigurierbar** (URL-Eingabe in den
  Einstellungen). Authentifizierung via PocketBase-Auth-Token.

### 2.2 iOS-App: Offline-First mit lokalem SQLite-Mirror

- **SwiftUI** + **GRDB** für lokale SQLite-Persistenz (GRDB wegen
  ausgereifter Migration und Sync-Tauglichkeit).
- **MapKit** mit OpenTopoMap-Tile-Overlay für topographische Sicht.
- **CoreLocation** für GPS und (optional) Reverse-Geocoding-Fallback.
- Sync-Layer zwischen lokalem SQLite und PocketBase: Sample-First,
  Last-Write-Wins, Konfliktauflösung über `client_uuid` + `client_updated_at`.
- Schreib- und Lesepfad **immer zuerst lokal**, Sync läuft asynchron im
  Hintergrund. Die App ist im Funkloch genauso schnell wie mit Internet.

### 2.3 Logik liegt im Backend, aber so, dass der Client offline arbeitet

Die echte Geschäftslogik (Code-Vergabe, Gruppierungs-Algorithmen,
Geocoding-Anreicherung) sitzt im Backend. Das ist wichtig für spätere
Web-/Android-Clients. Der iOS-Client repliziert nur die Mindest-Logik, die
**zwingend offline** funktionieren muss:

- **Provisorische Code-Vergabe** (`YYMMDD/N` aus lokalem Counter)
- **Provisorische Exkursionszuordnung** (Sammeltag)

Beim nächsten Sync validiert das Backend und korrigiert ggf. (Audit-Feld
`original_code` bleibt erhalten – der Aufkleber auf dem Röhrchen zählt).

---

## 3. Datenmodell

### 3.1 Drei Ebenen

```
Fundort  ─┬── Exkursion ── Aufsammlung (Sample) ── Determinationen
          │       │              │
          │       │              └── Fotos
          │       └── Habitat-Notizen, Pflanzen, Genehmigung
          └── (zeitübergreifend, manuell kuratiert)
```

- **Sample** (`samples`) – die einzelne Aufsammlung, kommt aufs Röhrchen.
  Trägt den Code `YYMMDD/N`. (DB-Bezeichnung englisch wegen Namenskollision
  mit PocketBase-Begriff „Collection".)
- **Fieldtrip** (`fieldtrips`) – ein Sammeltag (mit konfigurierbarem
  Rollover). Default: alle Samples eines Sammeltags = eine Exkursion.
- **Locality / Fundort** (`localities`) – zeitübergreifende Lokalität
  (z. B. „NSG Bla Blubbern"). Sammelt alle Exkursionen an diesem Ort.

### 3.2 PocketBase-Schema (geplant)

#### `samples`

| Feld | Typ | Notizen |
|---|---|---|
| `id` | text (PB) | |
| `code` | text, unique | `260509/3` |
| `original_code` | text | nur gesetzt, wenn umnummeriert |
| `fieldtrip` | relation → fieldtrips | required |
| `collected_from` | datetime | required |
| `collected_to` | datetime | nullable; null = punktuell |
| `date_precision` | enum | `instant` \| `day` \| `range_dates` \| `range_datetimes` |
| `lat`, `lon` | number | |
| `altitude_m` | number | nullable |
| `accuracy_m` | number | nullable |
| `coords_manual` | bool | true = auf Karte gesetzt |
| `mtb` | json | `{sheet_number, sheet_name, quadrant}` |
| `admin_units` | json | snapshot vom Reverse-Geocoder |
| `host_plant` | text | optional, freier Text |
| `notes` | editor | rich text |
| `collector` | relation → users | default = aktueller User (= leg.) |
| `photos` | file[] | |
| `client_uuid` | text | für Sync-Idempotenz |
| `client_updated_at` | datetime | für Konfliktauflösung |

#### `fieldtrips`

| Feld | Typ | Notizen |
|---|---|---|
| `id` | text (PB) | |
| `name` | text | default = Reverse-Geocode-Locality |
| `started_at`, `ended_at` | datetime | umschließt alle Samples |
| `collecting_day` | date | mit Rollover berechnet |
| `night_fieldtrip` | bool | true wenn `ended_at` Mitternacht überschreitet |
| `centroid_lat`, `centroid_lon` | number | inkrementell aktualisiert |
| `bbox` | json | `{min_lat, max_lat, min_lon, max_lon}` |
| `admin_units` | json | meist gleich wie Fundort |
| `mtb` | json | wenn alle Samples im selben MTB |
| `locality` | relation → localities | nullable |
| `permit_number` | text | |
| `permit_pdf` | file | nachreichbar |
| `habitat_notes` | editor | |
| `plants` | json | `[{name, source: 'manual'|'floraincognita', confidence, photo_id}]` |
| `weather` | text | optional |
| `astro` | json | Sonnen-/Mondzeiten + Mond-Sichtbarkeit, siehe §6.5 |
| `client_uuid`, `client_updated_at` | | |

#### `localities`

| Feld | Typ | Notizen |
|---|---|---|
| `name` | text | „NSG Bla Blubbern" |
| `centroid_lat`, `centroid_lon` | number | |
| `radius_m` | number | für Auto-Vorschläge |
| `polygon` | json | optional, für komplexere Gebiete |
| `admin_units` | json | inkl. Insel/Inselgruppe |
| `island` | text | normalisiert für Filter (`La Palma`) |
| `island_group` | text | (`Kanaren`) |
| `mtb` | json | wenn auf einem MTB liegend |
| `notes` | editor | |

#### `determinations`

| Feld | Typ | Notizen |
|---|---|---|
| `sample` | relation → samples | |
| `species_text` | text | freitext, später ggf. relation zur Taxonomie |
| `kind` | enum | `det` \| `t` \| `vid` |
| `person` | relation → people | wer hat es bestimmt |
| `determined_on` | date | |
| `notes` | text | |

#### `people`

Personen, die nicht zwingend App-User sind, aber für `det.`/`t.`/`vid.`/`leg.`
genannt werden müssen.

| Feld | Typ |
|---|---|
| `full_name` | text |
| `abbreviation` | text (z. B. „M. Müller" für Etiketten) |
| `email` | text, optional |
| `linked_user` | relation → users, optional |

#### `label_pdfs`

| Feld | Typ | Notizen |
|---|---|---|
| `kind` | enum | `locality` \| `determination` |
| `pdf_file` | file | |
| `samples` | relation[] → samples | welche Datensätze sind drauf |
| `template` | text | welches Template wurde verwendet |
| `generation_params` | json | komplette Eingabe zur Reproduktion |
| `generated_at` | datetime | |
| `superseded_by` | relation → label_pdfs | bei Neudruck |

#### `users` (PocketBase-Standard, erweitert)

| Feld | Typ | Notizen |
|---|---|---|
| `display_name` | text | für Default-leg./det. |
| `linked_person` | relation → people | für Etiketten |
| `day_cutoff_hour` | number | default 5 (= 05:00) |
| `default_fieldtrip_split_km` | number | default 15 |

---

## 4. Auto-Gruppierung (das Kernfeature)

### 4.1 Sammeltag mit Rollover

Pseudo-Code:

```python
def collecting_day(timestamp, cutoff_hour):
    # cutoff_hour = 5 -> Sample um 03:00 zählt zum Vortag
    shifted = timestamp - timedelta(hours=cutoff_hour)
    return shifted.date()
```

Der Sammeltag bestimmt:

- den Datumsteil im Code (`YYMMDD`),
- die Default-Exkursionszuordnung.

### 4.2 Exkursionszuordnung beim Erzeugen einer Aufsammlung

```
1. user.cutoff_hour anwenden -> collecting_day
2. Suche Exkursion mit selbem collecting_day des Users
3. Falls vorhanden -> Sample dort einhängen, Exkursions-Bbox/Centroid
   inkrementell updaten, ended_at ggf. nach hinten ziehen
4. Falls nicht vorhanden -> neue Exkursion anlegen mit Default-Name
   aus Reverse-Geocoding-Locality
```

**Es gibt keinen „Exkursion abschließen"-Knopf.** Die Exkursion ist
immer offen für weitere Samples desselben Sammeltags. Spätestens beim
nächsten Sammeltag wird sie de facto abgeschlossen, weil neue Samples
in eine neue Exkursion fallen.

### 4.3 Geographische Split-Vorschläge (asynchron, nicht im Feld)

Beim späteren Browsen / einmal nachts über einen Cron:

```
Für jede Exkursion:
  Cluster der Sample-Koordinaten (DBSCAN, eps = user.split_km)
  Wenn Cluster >= 2:
    erzeuge Split-Vorschlag (nicht ausführen)
  Vorschläge erscheinen in der Review-Ansicht der App
```

User akzeptiert oder verwirft mit einem Tap. Niemand muss im Feld nachdenken.

### 4.4 Manuelles Splitten / Mergen

Jederzeit möglich:

- **Merge:** mehrere Exkursionen auswählen → eine; alle Samples übernehmen,
  Bbox neu berechnen, älteste Permit/Notes behalten und Konflikte sichtbar
  machen.
- **Split:** einzelne Samples in eine neue/andere Exkursion verschieben.

### 4.5 Datums-Range-Samples (Fallen, historische Daten)

Samples mit `date_precision = range_dates` (z. B. Falle 1.–7.5.):

- Verwenden `collected_from` für die Exkursionszuordnung (Sammeltag = Tag des
  Aufstellens). Der User kann das im UI überschreiben.
- Erscheinen auf Etiketten als „1.–7.5.2026".

---

## 5. Code-Vergabe (`YYMMDD/N`)

### 5.1 Server (autoritativ)

PocketBase-Hook `OnRecordCreate("samples")`:

```go
day := collectingDay(record.GetDateTime("collected_from"), user.dayCutoffHour)
seq := nextSequenceForUserAndDay(app.DB(), user.ID, day)
record.Set("code", fmt.Sprintf("%s/%d", day.Format("060102"), seq))
```

Sequenz wird per Transaktion auf einer separaten Tabelle `sample_sequences`
(`user_id`, `collecting_day`, `last_seq`) hochgezählt – atomic increment.

### 5.2 Client (offline, provisorisch)

iOS hält dieselbe Sequenz lokal pro `(user, collecting_day)`. Beim Sync:

- Wenn der Server die identische Sequenz noch nicht vergeben hat → übernehmen.
- Sonst (nur möglich, wenn ein zweites Gerät parallel offline gesammelt hat):
  Server vergibt neuen Code, Client speichert den alten in `original_code`.

Da du faktisch Single-User auf einem Gerät arbeitest, ist Konflikt selten.

---

## 6. Externe Services

### 6.1 Reverse Geocoding (`labelloc.example.org`)

```
GET /api/location?lat=...&lon=...&lang=de
```

Antwortfelder, die wir nutzen: `country`, `countryIso`, `adminArea`,
`adminArea2`, `adminArea3`, `locality`, `description.locationDescription`.

**Backend-Hook** ruft den Service nach dem Speichern eines Samples
asynchron auf und füllt `admin_units` und – wenn die Exkursion noch
keinen Namen hat – den Exkursionsnamen.

**Wichtig:** Antwort scheint UTF-8-Encoding-Probleme zu zeigen
(`WÃ¼rzburg` statt `Würzburg`). Wir behandeln das defensiv im Wrapper:
re-decode versuchen, sonst Roh-Wert speichern und im Log markieren.

### 6.2 MTB (`coordstomtb.example.org`)

```
GET /api/coordinate?lat=...&lon=...&id=<sample.id>
```

Antwort liefert `sheet_number`, `sheet_name`, `quadrant`,
`sheet_boundaries` (für Karten-Ausschnitt). Wird ebenfalls asynchron
nachgepflegt.

### 6.3 Wrapper-Layer im Backend

`internal/services/labelloc.go`, `internal/services/mtb.go` – beide mit:

- Retry mit exponential backoff
- 7-Tage-Cache pro `(lat, lon, lang)` in einer eigenen PocketBase-Collection
  `geocache` (spart API-Calls und liefert Werte selbst bei Service-Ausfall)
- Strikt fehlertolerant: wenn der Service hängt, wird das Sample trotzdem
  gespeichert, nur die Anreicherung steht aus.

### 6.4 FloraIncognita (Phase später)

API-Details müssen recherchiert werden. Vorgesehen:

- Plant-Snapshot wird pro `fieldtrip.plants[]` gespeichert.
- Foto-Upload aus der App; Plant-ID wird zugeordnet, sobald die
  FloraIncognita-Antwort kommt.

### 6.5 Astronomische Anreicherung (lokal, kein externer Service)

Pro Exkursion werden Sonnen- und Mondzeiten am `centroid` für den
`collecting_day` berechnet und gespeichert. Anders als Geocoding und
MTB ist das **reine Mathematik** — kein externer Service, kein Cache,
kein Retry. Die Berechnung ist deterministisch und idempotent;
Live-Updates sind nicht nötig.

Wo die Logik sitzt: `backend/internal/astro/`. Pure Funktionen mit
Tests, analog zu `codes/` und `grouping/`. Empfohlene Library:
ein Go-Port von suncalc (`github.com/sixdouglas/suncalc` o. ä.) für
Sun/Moon-Position; falls Lizenz/Wartung problematisch, Eigenbau
basierend auf NOAA-Solar und Meeus-Mondalgorithmus.

`fieldtrip.astro` ist ein JSON-Snapshot, der bei jedem
Centroid-/Zeitfenster-Update vom Hook neu berechnet wird:

```json
{
  "sunrise":             "2026-05-09T05:42:00+02:00",
  "sunset":              "2026-05-09T20:51:00+02:00",
  "civil_twilight_end":  "2026-05-09T21:28:00+02:00",
  "moon_phase":          0.62,
  "moon_phase_name":     "abnehmender Mond",
  "moon_illumination":   0.78,
  "moon_rise":           "2026-05-09T22:14:00+02:00",
  "moon_set":            "2026-05-10T06:03:00+02:00",
  "moon_above_horizon_during_fieldtrip": true,
  "moon_altitude_max_during_deg":        38.4
}
```

Felder im Detail:

- `sunrise` / `sunset` / `civil_twilight_end` — am `centroid` für
  den `collecting_day`. Werden in der Fieldtrip-Detail-Ansicht
  angezeigt (Anforderung „Sammeltag mit Sonnenaufgang/-untergang in
  einer Ansicht").
- `moon_phase` — 0..1 (0 = Neumond, 0.25 = erstes Viertel,
  0.5 = Vollmond, 0.75 = letztes Viertel). `moon_phase_name` ist nur
  für die UI gedacht.
- `moon_illumination` — Anteil der beleuchteten Mondscheibe.
- `moon_rise` / `moon_set` — am `collecting_day` (kann auf den
  Folgetag fallen, dann ISO-Datetime entsprechend).
- `moon_above_horizon_during_fieldtrip` — **die kritische Frage für
  Lichtfang:** stand der Mond zwischen `started_at` und `ended_at` zu
  irgendeinem Zeitpunkt über dem Horizont? Berechnet via Mond-Altitude
  über das Fieldtrip-Zeitfenster (Schrittweite z. B. 5 min, oder
  analytisch via Mondrise/-set vs. Fieldtrip-Range).
- `moon_altitude_max_during_deg` — maximale Mondhöhe in Grad während
  der Exkursion. Indikator dafür, wie „wirksam hell" der Mond war
  (Mond knapp über Horizont stört Lichtfang weniger als hoch stehend).

Trigger für Neuberechnung: Sample-Insert/-Delete einer Fieldtrip
(verändert Centroid und Zeitfenster), Fieldtrip-Update (manuelle
Korrektur von Zeit/Ort).

Default-iOS-Verhalten: wartet auf Backend-Wert (Server-of-Truth). Falls
Pre-Trip-Vorschau („Mond steht heute Nacht hoch, taugt nicht für
Lichtfang") gewünscht wird, kann später eine Mini-Variante in
`ios/Fieldworksdiary/Core/Astro/` ergänzt werden — bewusst **erst wenn das
Bedürfnis konkret wird**, nicht prophylaktisch.

---

## 7. Karten-Ansicht in der iOS-App

### 7.1 Topographisch

MapKit mit `MKTileOverlay` auf OpenTopoMap:

```
https://a.tile.opentopomap.org/{z}/{x}/{y}.png
```

(Attribution einblenden!) Für Offline-Cache vorab Tiles für markierte
Regionen herunterladen (Phase 3).

### 7.2 Fundort-Detailkarte

Wenn ein Fundort/Exkursion angezeigt wird:

- Ausschnitt = MTB-Bounds (aus `mtb.sheet_boundaries.bounds`), evtl. um
  10 % gepuffert.
- Pins für jede Sample-Koordinate.
- Optional: MTB-Polygon als Overlay.

### 7.3 Filter-Karte

Karte über alle Fundorte mit Heatmap oder Cluster-Pins. Filter:

- Zeitraum: Jahr (`2025`), oder Monat-Tag-Range (`15.04.–15.05.`,
  jahresübergreifend).
- Region: Bundesland, Insel, Inselgruppe, MTB.

---

## 8. Filter-Logik (Backend)

### 8.1 Zeitraum

Zwei Modi:

```
mode = "absolute": collecting_day BETWEEN <from_date> AND <to_date>
mode = "seasonal": doy(collecting_day) BETWEEN doy(<from>) AND doy(<to>)
                   (Day-of-Year, jahresübergreifend)
```

Seasonal-Filter braucht eine berechnete Spalte `doy` auf `samples` und
`fieldtrips` (PocketBase: per Hook beim Insert/Update setzen).

### 8.2 Geographisch

Filter auf `admin_units.country`, `admin_units.adminArea` (Bundesland),
`island`, `island_group`. Diese Werte sind im JSON, aber wir indizieren
zusätzlich als flache Spalten (per Hook denormalisieren), damit Queries
schnell sind.

---

## 9. Etiketten-PDFs

Konzeptionell erst ab Phase 6, aber im Datenmodell vorgesehen.

### 9.1 Zwei Etikettentypen

- **Fundort-/Locality-Label** (kommt zuerst): Land, Region, Locality,
  Koordinaten, Höhe, Datum, Sammler.
- **Determinationsetikett** (später): Art, det./t./vid. + Person.

### 9.2 Generierungsprinzip

- Eingabe: ausgewählte Samples + Template-Name.
- Backend rendert PDF (z. B. mit `gofpdf` oder über LaTeX-Render-Service)
  auf A6-Bögen.
- **PDF und `generation_params` werden gespeichert** als `label_pdfs`
  Record. So kann das Label später identisch oder mit Korrekturen neu
  gedruckt werden (`superseded_by` zeigt auf den Nachfolger).

### 9.3 Locality-String auf dem Etikett

Konfigurierbares Template, default:

```
{country}, {adminArea}, {locality}
{lat:.5f} {lon:.5f}, {altitude}m
{date_string}, leg. {collector_abbreviation}
```

Bei Range-Samples: `1.–7.5.2026`. Bei `precision = day`: nur Datum, keine
Uhrzeit.

---

## 10. Repository-Layout

```
fieldworksdiary/
├── README.md
├── PROJECT_PLAN.md          (dieses Dokument)
├── CLAUDE.md                (Konventionen für Claude Code)
├── docker-compose.yml       (dev: backend + ggf. dev-DB)
├── docker-compose.prod.yml  (prod-Variante)
│
├── backend/
│   ├── Dockerfile
│   ├── go.mod
│   ├── main.go                    (PocketBase als Library, Hooks registrieren)
│   ├── internal/
│   │   ├── codes/                 (Code-Vergabe, Sequenz-Logik)
│   │   ├── grouping/              (Sammeltag, Auto-Gruppierung, Split-Vorschläge)
│   │   ├── services/
│   │   │   ├── labelloc.go        (Wrapper für Reverse-Geocoder)
│   │   │   ├── mtb.go             (Wrapper für MTB-Service)
│   │   │   └── geocache.go        (Cache-Layer)
│   │   ├── enrichment/            (asynchrone Anreicherungs-Jobs)
│   │   ├── filters/               (Zeitraum-, Region-Queries)
│   │   ├── pdf/                   (Etikettenrendering, Phase 6+)
│   │   └── sync/                  (Konfliktauflösung, client_uuid-Handling)
│   ├── migrations/                (PocketBase-Migrations als Go-Files)
│   └── pb_data/                   (Volume mount, gitignored)
│
├── ios/
│   ├── Fieldworksdiary.xcodeproj
│   ├── Fieldworksdiary/
│   │   ├── App/                   (Entry-Point, AppConfig, Endpoint-Setting)
│   │   ├── Features/
│   │   │   ├── AddSample/         (das „+"-Sheet)
│   │   │   ├── FieldtripList/
│   │   │   ├── LocalityList/
│   │   │   ├── Map/
│   │   │   └── Determination/
│   │   ├── Core/
│   │   │   ├── Persistence/       (GRDB-Setup, Migrations)
│   │   │   ├── Sync/              (Sync-Queue, Konflikt-Handling)
│   │   │   ├── PocketBaseClient/  (HTTP-Client, Auth)
│   │   │   ├── Geo/               (CoreLocation-Wrapper, Codes-Logik lokal)
│   │   │   └── Models/            (Domain-Modelle, mit Codable+GRDB-Mapping)
│   │   └── UI/                    (geteilte Views, Karten-Komponente)
│   └── FieldworksdiaryTests/
│
└── docs/
    ├── adr/                       (Architecture Decision Records)
    └── api.md                     (PocketBase-Endpoints, Custom-Routes)
```

---

## 11. Implementierungsphasen

Strikt inkrementell, jede Phase liefert lauffähige Software. **Wichtig:
Claude Code soll nicht alles auf einmal anlegen.** Reihenfolge ist auch
die der Sinnhaftigkeit für Tests.

### Phase 0 – Bootstrap (Tag 1)

- Repo-Layout anlegen (siehe oben)
- `docker-compose.yml` mit Backend-Service
- Minimaler `main.go`: PocketBase startet, leeres Schema
- iOS-Projekt anlegen mit Endpoint-Konfigurations-Screen (URL eingeben,
  in UserDefaults persistieren)
- iOS sendet einen Health-Check ans Backend, zeigt „verbunden / nicht
  verbunden" an
- Akzeptanzkriterium: `docker compose up`, App startet, Endpoint kann
  gesetzt werden, grüner Health-Status.

### Phase 1 – Core-Schema und Code-Vergabe (Tag 2–3)

- Migrationen für `samples`, `fieldtrips`, `localities`, `users`,
  `sample_sequences`
- Hook `OnRecordCreate("samples")`:
  - Sammeltag berechnen
  - Exkursion finden oder erzeugen
  - Code vergeben
  - Sample mit Fieldtrip verknüpfen
- iOS: „+"-Screen, der ein Sample mit nur GPS-Koordinaten + Code anlegt
  (online, ohne Sync-Layer noch)
- Akzeptanzkriterium: Mehrere Samples eines Tages landen automatisch
  in einer Exkursion, korrekte Codes.

### Phase 2 – Reverse-Geocoding, MTB und Astro (Tag 4–5)

- `internal/services/labelloc.go` und `mtb.go` mit Cache
- `internal/astro/`: pure Sonnen-/Mondzeiten-Berechnung am
  Fieldtrip-Centroid, plus `MoonAboveHorizonDuring(window, lat, lon)`
  und `MaxMoonAltitudeDuring(window, lat, lon)` (siehe §6.5). Tests
  > 80 % Coverage analog zu `codes/` und `grouping/`.
- Anreicherungs-Hooks (asynchron, in Goroutine):
  - nach Sample-Insert: Geocoding + MTB
  - nach Fieldtrip-Update (Centroid- oder Zeitfenster-Änderung): Astro
    neu rechnen, in `fieldtrip.astro` schreiben
- iOS zeigt angereicherte Daten (Locality, MTB, Sonnen-/Mondzeiten)
  sobald sie da sind
- Akzeptanzkriterium: Sample zeigt nach < 2 s den Ortsstring und MTB;
  Fieldtrip zeigt Sonnenauf-/-untergang und Mondphase, und für eine
  Test-Nachtexkursion ist `moon_above_horizon_during_fieldtrip` korrekt
  gegen eine bekannte Referenz (z. B. timeanddate.com) verifiziert.

### Phase 3 – Offline-First (Tag 6–9)

- iOS: GRDB-Schema spiegelt PocketBase-Schema
- Sync-Queue: alle Schreiboperationen lokal, Hintergrund-Push
- Lokale Code-Vergabe (Sequence-Counter pro `(user, collecting_day)`)
- Manuelles Setzen der Koordinate über Karte (GPS-Fallback)
- Konfliktauflösung beim Pull
- Akzeptanzkriterium: Flugmodus → 10 Samples anlegen → Internet wieder
  da → alles oben, Codes konsistent, Reverse-Geocoding nachgepflegt.

### Phase 4 – Fundort-Verwaltung und Vorschläge (Tag 10–11)

- Manuelles Anlegen von Fundorten
- Auto-Vorschlag: bei Exkursionsabschluss (= Übergang zum nächsten
  Sammeltag) prüft Hook, ob ein bestehender Fundort räumlich passt
- iOS: Vorschlag „Diese Exkursion liegt im Fundort X – zuordnen?"
- Akzeptanzkriterium: Mehrere Exkursionen werden korrekt einem Fundort
  zugeordnet; manuelle Korrektur möglich.

### Phase 5 – Filter, Suche, Listen (Tag 12–14)

- Backend: Filter-Endpoints für Zeitraum (absolut + seasonal), Region,
  Insel, MTB
- iOS: Listen mit Filtern, Karten-Ansicht aller Fundorte
- Akzeptanzkriterium: „Zeige alle Aufsammlungen 15.04.–15.05. über alle
  Jahre auf den Kanaren" funktioniert.

### Phase 6 – Determinationen und Personen (Tag 15–16)

- Schema `determinations`, `people`
- iOS: Determinations-Screen pro Sample, det./t./vid. wählen, Person
  suchen oder anlegen, Default = aktueller User
- Akzeptanzkriterium: Mehrere Determinationen pro Sample, korrekte
  Anzeige in Listen.

### Phase 7 – Etiketten-PDFs (Tag 17–20)

- Backend: PDF-Renderer (Empfehlung: `gofpdf` für Start; LaTeX später)
- Templates: locality-label, determination-label
- `label_pdfs`-Records, Reprint-Funktion
- iOS: Auswahl mehrerer Samples → „PDF erzeugen" → Download
- Akzeptanzkriterium: A6-Bogen mit korrekten Etiketten, Korrektur und
  Neudruck mit `superseded_by`-Verkettung möglich.

### Phase 8 – Genehmigungen (Tag 21)

- `permit_number` und `permit_pdf` auf `fieldtrips`
- iOS: PDF-Upload zur Exkursion
- Etiketten-Template kann optional Permit-Nummer enthalten

### Phase 9 – FloraIncognita-Integration (offen)

- Recherche der API
- Plant-Photos als Asset bei Exkursion oder Fundort
- Verknüpfung Plant-Bestimmung ↔ Exkursion ↔ Sample.host_plant

### Phase 10 – Politur und App-Store-Vorbereitung (offen)

- TestFlight-Build
- Datenschutzerklärung
- Backup/Export-Funktion (alle eigenen Daten als JSON-Dump)

### Phase 12 – Production-Härtung

Tests + UX-Politur für die Stellen, die heute mit unangetastet sind oder
nur partiell unter Test-Schutz stehen. Ziel: Refactors in Hot-Pfaden
fangen rote Tests statt stiller Bugs, A11y-Audit deckt die volle
Kategorien-Liste ab.

- Tests für iOS-Hydrators (`FieldtripsHydrator`, `LocalitiesHydrator`,
  `SamplesHydrator`) — derzeit ungetestet
- Tests für `AuthSession` + `AuthClient` (Token-Restore, Apple-Sign-In-
  Pfad inkl. Refresh)
- Tests für `internal/services/geocache.go` (aktuell 48 % Coverage,
  externes Service-Caching mit TTL-Logik)
- Hydrator-Konsolidierung: gemeinsame Base-Klasse / Generic-Type für die
  drei nahezu identischen Implementierungen
- A11y-Sprint: `.contrast`, `.dynamicType`, `.textClipped` im
  `AccessibilityAuditTests` reaktivieren — Farb-Tokens definieren,
  AX-Layouts gegen die maximale Schriftgröße prüfen
- Down-Migrations für PocketBase + GRDB (aktuell forward-only)

### Phase 13 – Tile-Caching / Offline-Map

Während Phase 3 nur die Pin-Layer offline-fähig gemacht hat, fehlen
die Hintergrund-Tiles. Im Berg-/Wald-Einsatz ohne Mobilfunk ist das
limitierend.

- Tile-Provider auswählen (Apple Maps tile-cache, OpenStreetMap,
  Swisstopo o. ä.)
- Lokaler MBTiles-Store, Vorab-Download per Auswahl-Rechteck
- Cache-Größen-Limit + Manuelles-Aufräumen-UI
- Map-View nutzt Tile-Store automatisch, fällt offline auf Cache zurück

### Phase 14 – UI-Redesign: Home-Dashboard + Sample-Foto

Den feldtauglichen Workflow der Vorgänger-App nachbauen: grünes
Home-Dashboard mit Active-Collector / Active-Fieldtrip /
Recently-Sample und einem prominenten +-FAB ersetzt die 5-Tab-Bar als
Haupteinstieg. Sample-Erfassung um Notizen-Freitext und Foto-Aufnahme
erweitert. Phase 12 (Color-Tokens + A11y-Audit) wird hier integriert.

- Theme & Color-Tokens (Light + Dark, WCAG-AA-konform) — erfüllt
  damit das Phase-12-Color-Token-Ziel
- Home-Dashboard ersetzt MainTabs als Haupteinstieg; Navigation läuft
  über `NavigationStack` und Sheets
- Sample-Formular: Notizen-`TextEditor` + Foto-Galerie mit
  Kamera/Library-Picker, Multi-Foto pro Sample
- Backend: neue Collection `sample_photos` (separate Collection statt
  File-Array, einzeln nachreichbar, max 10 MB pro File, owner-scoped)
- iOS-Persistence: GRDB-Tabelle `local_photos` + JPEG-Kompression vor
  Upload
- SyncRunner pusht Fotos nach erfolgreichem Sample-Push, idempotent
  über `client_uuid`
- A11y-Audit auf neuen Views ohne `.subtracting(...)`, Dynamic Type AX5
  ohne Clipping (erfüllt damit auch die Phase-12-A11y-Ziele für die
  neuen Screens)
- Bewusst ausgeklammert (Phase 14b/c): Marked Samples, Photos-Galerie,
  Calendar-View, Sample-Map als Placeholder-Stubs im Menü

---

## 12. Offene Designfragen (am Ende von /init festhalten)

1. **Datums-Granularität für Range-Samples auf Etiketten:** Ist
   `1.–7.5.2026` immer richtig, oder gibt es Fälle wo Uhrzeiten relevant
   sind (z. B. nächtliche Lichtfangserie)?
2. **MTB außerhalb Deutschlands:** Der MTB-Service liefert wahrscheinlich
   nur DE-Bezüge. Wie verhalten wir uns auf den Kanaren? (Wahrscheinlich:
   `mtb` bleibt leer, kein Fehler.)
3. **Mehrere Sammler pro Exkursion:** Brauchen wir das? (`leg.` ist meist
   der App-User, aber gemeinsame Touren kommen vor.) Vermutlich
   `fieldtrip.collectors []relation` ergänzen.
4. **Foto-Speicherort:** PocketBase-File-Storage reicht initial. Bei
   wachsendem Volumen S3-kompatibler Storage erwägen.
5. **Sicherer Endpoint-Konfig in iOS:** sollte URL signieren oder
   Pinning haben, sobald App im App Store ist.

---

## 13. Was Claude Code im `/init` tun soll

1. Diesen Plan lesen.
2. Repo-Skelett gemäß Abschnitt 10 anlegen.
3. `CLAUDE.md` (siehe separate Datei) übernehmen oder als Grundlage nehmen.
4. Phase 0 vollständig umsetzen, Phase 1 beginnen.
5. Tests gleich mit anlegen (Backend: Go-Tests für `codes/` und
   `grouping/`, weil dort die Kernlogik sitzt).
6. **Nicht alle Phasen auf einmal!** Nach Phase 0 stoppen und Demo zeigen.

---

## 14. Tech-Stack-Zusammenfassung

| Bereich | Wahl | Begründung |
|---|---|---|
| Backend-Sprache | Go | PocketBase ist Go, native Hooks |
| Backend-Framework | PocketBase als Library | Auth, REST, Realtime, Admin-UI gratis |
| DB | SQLite (via PocketBase) | reicht für Single-User-Workload locker |
| Container | Docker / docker-compose | portabel, NAS-tauglich |
| iOS-UI | SwiftUI | moderner Stack, Apple-Plattform-First |
| iOS-DB | GRDB (SQLite) | reife Sync-Story, gute Migration-Support |
| iOS-Maps | MapKit + OpenTopoMap-Tiles | topographisch, OSM-konform |
| iOS-GPS | CoreLocation | Standard |
| PDF (später) | gofpdf (initial), LaTeX-Service (optional) | unkomplizierter Start |
