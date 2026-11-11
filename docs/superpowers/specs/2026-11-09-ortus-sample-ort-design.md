# Design: Ortsdaten am Sample über Ortus (Vorhaben A)

Stand: 2026-11-09 · Status: Entwurf zur Freigabe

## 1. Absicht und Warum

Beim Anlegen eines Samples sollen die Ortsangaben (Land, Verwaltungs-
einheiten, Insel, Gebirge, MTB) und die räumlichen Features der
Koordinate **sofort im Feld** verfügbar sein — online direkt aus Ortus,
offline nachträglich über das Backend. Ortus ersetzt die bisherigen
Dienste labelloc (Reverse-Geocoding) und coordstomtb (MTB) vollständig.

Gründe:

- Die heutige Anreicherung kommt am Sample nicht an: `samples.admin_units`
  existiert seit R7.4 nicht mehr, iOS liest es trotzdem; die
  Sample→Locality-Verknüpfung erreicht den Server nie (siehe Analyse im
  Gespräch vom 2026-11-08).
- Die App soll in der ganzen Westpaläarktis (77 Länder im Ortus-
  Gazetteer) funktionieren. Admin-Level haben je Land eine andere
  Bedeutung; die Anzeige muss das mit den richtigen Begriffen
  beschriften — auch wenn der User Ortsdaten offline von Hand eingibt.
- Die Features werden später für Folge-Screens gebraucht (z. B. EUNIS-
  Habitatbestimmung für einen Pflanzenplot über einen externen Dienst).
- Jo arbeitet draußen offline und synchronisiert Änderungen bei der
  Rückkehr. Redundante Speicherung (App-lokal + Backend) ist gewollt.

## 2. Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**

1. Ein neues Sample erfasst aus dem GPS: `latitude`, `longitude`,
   `elevation`, `horizontal_accuracy`, `vertical_accuracy`,
   `location_source = location_service`.
2. Online fragt die App Ortus (`/api/v1/query`) direkt ab; Ortsfelder,
   MTB und Features erscheinen sofort im Sample-Screen und werden lokal
   gespeichert.
3. Offline angelegte Samples werden nach dem Sync vom Backend über Ortus
   angereichert (Ortsfelder + Features).
4. Ortsdaten liegen in **flachen Spalten** (kein JSON) in einem
   **Placemark**, den mehrere Samples teilen, solange die Werte gleich
   sind.
5. Jedes Ortsfeld wird mit einem **länderspezifischen Begriff** beschriftet
   (z. B. „Comunidad autónoma“), darunter der übersetzbare generische
   Typ — auch offline und bei manueller Eingabe.
6. Features werden **pro Sample** gespeichert und sind über `source_id`
   abrufbar.
7. In Deutschland kommt das MTB aus dem Feature `tk25-blattschnitt-de`;
   Nummer und Blattname werden angezeigt.
8. labelloc und coordstomtb werden vollständig entfernt.

**Nicht-Ziele (eigene Vorhaben)**

- **B:** Was ein Fieldtrip künftig ist (persistent vs. on-the-fly-
  Gruppierung). In A bleiben Fieldtrips, wie sie sind — bis auf den
  Wegfall der labelloc-/MTB-abgeleiteten Felder.
- **C:** Gemeinschaftsexkursionen mit geteiltem Fundort. A fasst
  `localities` konzeptionell nicht an (siehe §4.6).
- **D:** Etiketten-Modul (Abkürzungen, Konfiguration, Entolabel-CSV).
- Der EUNIS-Screen selbst; Wetterdaten; Übersetzung der UI in weitere
  Sprachen (A muss i18n nur *ermöglichen*).

**Anti-Ziele (wäre ein Fehlschlag, auch wenn es technisch läuft)**

- Offline muss der User für ein Sample einen Meter neben dem vorigen die
  Ortsdaten erneut komplett eintippen.
- Ortus überschreibt still etwas, das der User von Hand eingegeben oder
  korrigiert hat.
- Das Speichern eines Samples wartet auf Netz oder Ortus.
- Ein Ortsfeld trägt ein falsches oder unverständliches Label (Wiki-Text
  wie „Comunidades autónomas (Autonomous communities, NUTS 2)“), sodass
  bei manueller Eingabe unklar ist, was wohin gehört.

## 3. Rahmenbedingungen

- Konventionen aus `CLAUDE.md` und `.claude/rules/*` gelten (Logging,
  A11y, Design-System, Conventional Commits, Offline-First: Schreib-
  vorgänge zuerst lokal, Sync-Queue pusht nach).
- Die in CLAUDE.md verlangte Nicht-Duplizierung von Backend-Logik in iOS
  wird hier **bewusst** aufgehoben: Ortus-Aufruf und Ortus→Spalten-
  Mapping existieren in App *und* Backend. Beide lesen dieselbe
  Label-Tabelle (§4.3), damit sie identisch mappen.
- Externe Calls im Backend laufen über einen eigenen Wrapper in
  `backend/internal/services/` mit Retry, Timeout und Cache
  (`geocache`), nie direkt aus Hooks, Anreicherung in Goroutines mit
  Recover.
- Ortus-Endpoint ist konfigurierbar: App über `AppConfig` (eine Stelle,
  injiziert), Backend über Env-Variable. `https://ortus.dev` war am
  2026-11-08 vom Entwickler-Mac aus nicht erreichbar (Timeout) — ein
  erreichbarer Endpoint ist Voraussetzung für den Live-Test.
- Ortus-API-Referenz: `../ortus/docs/reference/http-api.md`. Golden-
  Antworten: `../ortus/internal/app/testdata/gazetteer-golden.json`.
- Admin-Level-Referenz: `../geopackages/osm-data/admin_levels_west_palearctic.yaml`
  (byte-gleich mit `../ortus/data/gazetteer/…`). Ortus' `local_term` ist
  wörtlich das `name`-Feld dieser YAML.
- TK25-Paket: `../geopackages/mtb/` — Layer `sheets`, Properties `id`
  (Blattnummer), `dtknummer`, `blattname`.
- Strikt inkrementell nach `PHASES.md`; Statuswechsel dort zuerst
  eintragen.

## 4. Entscheidungen

### 4.1 Sample-Felder

| Feld | Bedeutung |
|---|---|
| `latitude`, `longitude` | WGS84, 6 Nachkommastellen |
| `elevation` | Meter. **Umbenannt aus `altitude`** (Konsistenz mit Ortus und Darwin Core) — in Backend und iOS |
| `horizontal_accuracy`, `vertical_accuracy` | Meter, aus dem GPS. `vertical_accuracy` wird ab jetzt tatsächlich übertragen |
| `location_source` | `location_service` (GPS) · `user` (Kartenpunkt / manuelle Koordinate). Die manuelle Koordinate setzt **nicht** mehr fälschlich `location_service` |
| `elevation_source` *(neu)* | `location_service` (GPS) · `backend_service` (DEM-Höhe aus Ortus) · `manual` (vom User eingetragen, z. B. mit eigenem Höhenmesser gemessen). In Swift: `.locationService` / `.backendService` / `.manual` |
| `placemark` *(neu)* | Relation → `placemarks` |
| `location_status` *(neu)* | `backend_service` (vom Ortus bestätigt) · `inherited` (offline vom vorigen Sample übernommen, noch unbestätigt) · `manual` · `pending` (noch keine Ortsdaten) |
| `mtb_sheet_number`, `mtb_sheet_name` *(neu, flach)* | Aus `tk25-blattschnitt-de`; nur bei Land = DE gefüllt, sonst leer (kein Fehler) |
| `mtb_quadrant` *(neu)* | **Selbst berechnet** (1 = NW, 2 = NO, 3 = SW, 4 = SO) aus der Koordinate im TK25-Raster: Blattzeilen ab 55°54′ N in 6′-Schritten nach Süden, Blattspalten ab 5°50′ O in 10′-Schritten nach Osten (an der Dev-DB verifiziert: 49.6623, 10.0716 → 6326/1). Reine Funktion in Backend und iOS mit gleichen Testfällen. `quadrant_row`/`quadrant_column` des alten Dienstes werden nicht übernommen — ihre Semantik lässt sich aus den Bestandsdaten nicht eindeutig ableiten *(Entscheidung Claude)* |
| `mtb` (JSON) | **entfällt** |

Zusätzlich aus dem Ortus-Gazetteer, flach am Sample (nicht im geteilten
Placemark, weil sie sich auf wenigen Metern ändern) *(Entscheidung
Claude)*:

| Feld | Quelle |
|---|---|
| `elevation_dem`, `elevation_dem_accuracy` | `gazetteer.elevation.meters` / `accuracy_m` — als Referenzwert gespeichert; in `elevation` wandert er nur nach der Regel unten |
| `slope_deg`, `aspect_deg`, `aspect_compass`, `terrain_flat` | `gazetteer.exposure` (relevant für spätere EUNIS-Bestimmung; vermeidet einen zweiten Backfill) |
| `bearing_label`, `bearing_reference`, `bearing_distance_km`, `bearing_compass`, `bearing_inside` | `gazetteer.bearing` („4 km E Würzburg“ / „in Würzburg“) — Rohstoff für das spätere Etiketten-Modul |

**Höhen-Regel:** Die DEM-Höhe aus Ortus wird **nur** verwendet, wenn
eine Koordinate, aber keine Höhe vorhanden ist — z. B. weil die
Koordinate manuell ohne Höhe eingegeben oder auf der Karte gesetzt
wurde. Dann: `elevation = elevation_dem`, `elevation_source =
backend_service`, `vertical_accuracy` aus Ortus' `accuracy_m`. Eine
GPS-Höhe (`location_service`) oder eine vom User eingetragene Höhe
(`manual`) wird nie durch die DEM-Höhe ersetzt, auch nicht bei einer
Neuabfrage nach Koordinatenkorrektur.

### 4.2 Placemark

Ein Placemark ist die **maschinelle Ortsbeschreibung** (was aufs Etikett
kommt). Er wird von Samples geteilt, solange die Werte gleich sind;
unterscheiden sie sich, entsteht ein neuer.

Spalten (alle flach):

- `country_iso` (ISO 3166-1 alpha-2)
- Pro generischem Typ eine Spalte für den Namen:
  `admin_country`, `admin_state`, `admin_region`, `admin_province`,
  `admin_county`, `admin_district`, `admin_municipality`,
  `admin_borough`, `admin_parish`, `admin_submunicipality`, `admin_other`
- Pro Typ zusätzlich `admin_<typ>_level` (OSM-Level, Zahl) und
  `admin_<typ>_native` (Originalschrift, leer wenn schon lateinisch)
- `island`, `mountain_range`, `mountain`
- `geocoding_source`: `backend_service` (Ortus) · `manual` (Swift:
  `.backendService` / `.manual`). **Vereinheitlichung auf Unterstriche:**
  Alle Wire-Werte der Source-/Status-Felder werden snake_case. Eine
  Bestandsmigration benennt `backend-service` → `backend_service` um —
  Select-Optionen der Collection und vorhandene Zeilen in `placemarks`
  im Backend, `local_placemarks` per GRDB-Migration in iOS. Der iOS-
  Decoder akzeptiert übergangsweise beide Schreibweisen, bis Backend und
  App migriert sind.
- `geocoding_date`, `geocoding_service_version` (Ortus-Gazetteer-
  `dataset_version`)
- `dedup_hash` über alle Ortsspalten (NFC, lowercase) — eindeutig je
  `geocoding_source`/Owner-Kombination

Die bisherigen labelloc-Spalten (`administrative_area`,
`sub_administrative_area`, `locality`, `sub_locality`, `postal_code`,
`name`, `thoroughfare`) entfallen; vorhandene Werte werden beim Backfill
ersetzt (§4.9).

**Owner:** Ortus-Placemarks bleiben eine owner-lose Referenztabelle
(gleiche Koordinate → gleiches Ergebnis für alle). Manuelle Placemarks
sind Nutzerdaten und tragen einen `owner`. Weil die App jetzt auch
Placemarks anlegt (online aus Ortus, offline/manuell), braucht die
Collection eine Create-Möglichkeit für authentifizierte User; der Server
dedupliziert über `dedup_hash` und remappt die lokale UUID auf die
bestehende ID (gleiches Muster wie heute bei Localities).

**Regeln:**

- Ortus-Ergebnis für ein Sample → Placemark mit identischem Hash wird
  wiederverwendet, sonst neu angelegt.
- **Manuelle Änderung eines Ortsfelds an einem Sample** trennt nur dieses
  Sample ab: neuer Placemark mit `geocoding_source = manual` und
  `location_status = manual`. Andere Samples bleiben unberührt.
- **Offline ohne Ortus:** Ein neues Sample übernimmt den Placemark des
  **vorigen Samples desselben Sammeltags** (`location_status =
  inherited`). Gibt es keins, gibt der User die Ortsdaten manuell ein
  (§4.5) oder sie bleiben `pending`.

### 4.3 Label-Tabelle (alle 77 Ortus-Länder)

Eine gepflegte Datei im Repo (gleicher Inhalt in iOS-Bundle und Go-
`embed`), Schlüssel Land (ISO) × OSM-Level:

- **Zielspalte** (einer der elf `admin_*`-Typen oder „nicht speichern“)
- **Landesbegriff im Singular**, bereinigt (kein Wiki-Text, keine
  Klammer-Erklärungen, eine Sprache), z. B. ES 4 → `admin_state`,
  „Comunidad autónoma“; IT 4 → `admin_state`, „Regione“.

Die Tabelle löst damit beide Probleme der Rohdaten an einer Stelle:

- **Uneinheitliche Typen:** Die YAML ordnet gleiche Rollen verschiedenen
  Typen zu (ES 4 = `state`, IT 4 = `region`). Die Tabelle legt die
  Zielspalte pro Land fest.
- **Doppelungen:** In 76 Fällen teilen sich mehrere Level eines Landes
  denselben Typ (z. B. DE 10/11/12 `submunicipality`, PL 7/8
  `municipality`). Die Tabelle weist jedem (Land, Level) genau eine
  Spalte zu oder verwirft das Level.

Entstehung: Ein Skript erzeugt aus der YAML einen ersten Entwurf (Spalte
aus `equivalent`, Begriff aus `name`), danach wird pro Land bereinigt.
Die Bereinigung von ~600 Levels ist eine **eigene Phase vor dem
App-Umbau** und geschieht gemeinsam mit Jo.

**Anzeige** jedes Ortsfelds:

```
Comunidad autónoma        ← Landesbegriff (unübersetzt, Fachbegriff des Landes)
1. Verwaltungsebene       ← generischer Typ, i18n über die App-Strings
[ Canarias            ]
```

**Versionierung** *(Entscheidung Claude)*: Die Tabelle trägt ein
Versionsfeld. Placemarks speichern pro Spalte das OSM-Level
(`admin_<typ>_level`), deshalb wird das Label immer zur Anzeigezeit aus
der aktuellen Tabelle aufgelöst — Begriffskorrekturen wirken sofort ohne
Datenänderung. Ändert eine neue Tabellenversion eine **Zielspalte**,
mappt ein Backend-Job betroffene Ortus-Placemarks neu (`manual` bleibt
unberührt). Backend- und iOS-Arbeit dürfen auf dem Skript-Entwurf
starten; die Bereinigung läuft parallel, Abnahme durch Jo pro Land.

Fallback-Reihenfolge für das Label: Tabelle(Land, Level) → Ortus-
`local_term` (roh) → nur generischer Typ. Ohne bekanntes Land zeigt das
Formular nur die generischen Typen.

Die generischen Typ-Labels sind Lokalisierungsschlüssel (z. B.
`admin.state`), damit i18n später ohne Änderung an der Tabelle kommt.

### 4.4 Ablauf beim Anlegen

1. Sample wird **sofort lokal** gespeichert (ohne Speicher-Button bleibt
   Phase-14-Thema; A ändert den Erfassungsflow nur, wo nötig).
2. GPS liefert Koordinate, Höhe, Genauigkeiten.
3. **Online:** App ruft Ortus `/api/v1/query` (Gazetteer + Features in
   einem Aufruf). Mapping über die Label-Tabelle → Placemark
   (wiederverwenden oder neu), Features und MTB lokal speichern,
   `location_status = backend_service`. Ein Ortus-Fehler/Timeout blockiert nichts;
   das Sample verhält sich dann wie offline.
4. **Offline:** Placemark vom vorigen Sample des Tages übernehmen
   (`inherited`) oder `pending`.
5. **Sync:** Sample, Placemark (falls lokal neu) und Features gehen an
   das Backend. Online gewonnene Features werden mitgeschickt.
6. **Backend nach dem Sync:** Hat das Sample eine Koordinate und ist
   `location_status` nicht `backend_service`/`manual`, ruft das Backend Ortus auf,
   setzt Placemark, Features und MTB. Weicht das Ergebnis vom geerbten
   Placemark ab, bekommt das Sample den neuen (Split). Die App holt das
   Ergebnis beim nächsten Abgleich.

### 4.5 Manuelle Eingabe und Kartenpunkt

- **Keine Koordinate:** Der User muss einen Punkt auf der Karte setzen
  (`location_source = user`). Danach werden Placemark, Features, MTB und
  die DEM-Höhe aus Ortus geholt (online sofort, sonst nach dem Sync).
- **Ortsdaten von Hand:** Erst wird das Land gewählt (Liste mit ISO-
  Code), dann zeigt das Formular nur die Ebenen dieses Landes in
  Hierarchie-Reihenfolge, beschriftet nach §4.3, plus Insel und Gebirge.
  Beispiel „Spanien, Canarias, La Palma“: Land = Spanien,
  Comunidad autónoma = Canarias, **Insel** = La Palma (La Palma ist keine
  Verwaltungsebene).

### 4.6 Locality bleibt getrennt

`localities` sind die *von Menschen gepflegte* Fundortreferenz (Basis für
Vorhaben C, „Fundort 23“). A ändert daran konzeptionell nichts. Weil
labelloc entfällt, wird der bestehende Locality-Placemark-Enricher auf
Ortus und das neue Placemark-Schema umgestellt. Über `dedup_hash` teilen
sich Locality und Sample automatisch denselben Placemark, wenn Ortus
dasselbe liefert — keine doppelten Ortsdatensätze.

*(Entscheidung Claude)* Der in der Analyse gefundene Sync-Bug wird in A
mit repariert, weil A denselben Sync-Code anfasst: Der Sample-Create
schickt `locality` mit, und die Antwort des Servers überschreibt eine
lokal gesetzte Locality nicht mehr mit leer (`SyncRunner.swift`,
`working.locality = created.locality`). Erfassungsflow und Offline-
Fusion der Localities bleiben sonst unverändert.

### 4.7 Koordinatenkorrektur

Ändert sich die Koordinate eines Samples, werden Placemark, Features und
MTB neu geholt (online sofort durch die App, sonst durch das Backend
nach dem Sync). Ist der aktuelle Placemark `manual`, wird **vorher
gefragt**; der User entscheidet, ob seine Handeingabe bleibt. Das
Backend kann nicht fragen: Trifft es auf einen `manual`-Placemark mit
abweichendem Ortus-Ergebnis, überschreibt es nicht, sondern legt einen
Vorschlag ab, den die App dem User zur Zustimmung zeigt.

### 4.8 Features

- Eigene Collection `sample_features` (owner-scoped), eine Zeile pro
  Ortus-Feature: `sample`, `source_id`, `source_name`, `layer`,
  `feature_id`, `properties` (JSON — die einzige JSON-Spalte, weil jede
  Quelle andere Properties hat), `license`, `fetched_at`.
- Alle von Ortus gelieferten Quellen werden gespeichert. Bei einer
  Neuabfrage (§4.7) wird der Feature-Satz des Samples komplett ersetzt.
- Lokal in GRDB gespiegelt; Abruf über (Sample, `source_id`).
- MTB wird zusätzlich als `mtb_sheet_number`/`mtb_sheet_name` am Sample
  denormalisiert (Listen, Etiketten, Filter).

### 4.9 Was wegfällt bzw. umgestellt wird

- `services.Labelloc`, `services.MTB`, der Sample-Teil des `Enricher`,
  die Konstanten in `main.go`.
- Fieldtrips: `admin_units`, `mtb` und die Titel-Hochstufung aus
  labelloc. Astro, Zentroid und `suggested_locality` bleiben.
- **Etiketten sind ein eigenes Vorhaben (D)**: Abkürzungen,
  konfigurierbare Etiketten, CSV-Export für Entolabel. A gestaltet
  Etiketten nicht neu. Damit die vorhandenen Etiketten-PDFs nicht
  brechen, liest `internal/api/labels.go` minimal um. Auf dem Etikett
  stehen: **Land, Bundesland, Stadt** (`admin_country`, `admin_state`,
  `admin_municipality` aus dem Placemark des Samples statt
  `fieldtrips.admin_units`), **Koordinate, Datum** und **leg.
  &lt;Sammler&gt;**. Das MTB kommt aktuell **nicht** aufs Etikett. Mehr
  nicht.
- Weitere abhängige Leser umstellen: Export,
  Phase-5-Filterspalten (`country`, `admin_area` am Fieldtrip), iOS-
  Anzeigen von `adminUnitsLocality`/`mtbSheetNumber`.
- **Fieldtrip-Filterspalten** `country`/`admin_area`: entfallen. Der
  Filter läuft künftig über die Placemarks der Samples (ein Fieldtrip
  passt, wenn mindestens eines seiner Samples passt). Kein neuer
  Aggregations-Hook am Fieldtrip — passt zu Vorhaben B, wo Fieldtrips
  ohnehin neu gedacht werden.
- **Der Begriff „Placemark“ ist in der UI nie sichtbar.** Er ist ein
  internes Modell. Der User sieht und filtert nach den Ortsfeldern
  selbst — Land, Bundesland, Ort usw., beschriftet nach §4.3. Das gilt
  für Filter, Sample-Screen, Formulare, Hinweise und Fehlermeldungen
  (z. B. heißt die Rückfrage aus §4.7 sinngemäß „Ortsangaben neu
  übernehmen?“, nicht „Placemark ersetzen?“).
- **Bestand (Backfill):** Ein einmaliger Backend-Job fragt für alle
  vorhandenen Samples mit Koordinate Ortus ab und füllt Placemark,
  Features, MTB und Gelände-Felder; erst danach werden alte Spalten
  entfernt.
- **Bestehende manuelle Placemarks** *(Entscheidung Claude)*: werden
  nicht überschrieben. Die Migration mappt die alten Felder bestmöglich
  (`country` → `country_iso`, `administrative_area` → `admin_state`,
  `sub_administrative_area` → `admin_county`, `locality` →
  `admin_municipality`, `sub_locality` → `admin_submunicipality`),
  setzt `owner` aus der referenzierenden Locality, behält `manual` und
  schreibt jede gemappte Zeile mit Alt- und Neuwerten ins Log, damit Jo
  sie prüfen kann. Die alten Spalten werden erst danach entfernt.

## 5. Was dem Builder überlassen ist

- Phasenschnitt im Detail. Vorschlag: (1) Label-Tabelle (Skript +
  Bereinigung), (2) Backend (Schema, Ortus-Wrapper, Mapping,
  Anreicherung, Entfernen labelloc/MTB), (3) iOS (GRDB, Ortus-Client,
  Sample-Screen, manuelles Formular, Sync), (4) Backfill und Aufräumen.
- Ob die App Sample + Placemark + Features über einzelne PocketBase-
  Records oder einen eigenen Backend-Endpoint synchronisiert — solange
  der Sync idempotent (`client_uuid`) und Offline-First bleibt.
- Form des Vorschlags-Mechanismus aus §4.7.
- Cache-Schlüssel für Ortus im `geocache` (z. B. Koordinate auf 6
  Nachkommastellen), Timeouts, Retry-Parameter.
- Dateiformat und Ort der Label-Tabelle (JSON/YAML, z. B. unter
  `shared/`).
- Tests: Mapping-Logik im Backend mit > 80 % Coverage, Golden-Tests mit
  den Ortus-Testdaten; iOS-Unit-Tests für Mapping und Sync.

## 6. Offene Punkte

- **Ortus-Instanz:** Welche Instanz App und Backend produktiv nutzen und
  ob dort TK25, Inseln, Gebirge und DEM geladen sind, ist noch offen.
  Solange keine erreichbare Instanz feststeht, sieht der Plan als ersten
  Schritt eine lokale Ortus-Instanz (Docker, mit diesen Paketen) für
  Entwicklung und Tests vor. Endpoint ist ohnehin konfigurierbar.

Spätere Vorhaben, auf die A Rücksicht nimmt: **B** Fieldtrip neu
denken, **C** Gemeinschaftsexkursionen, **D** Etiketten-Modul.
