# Wetter, Klima und Astronomie pro Sample über Tempus

Stand: 2026-11-19. Status: Entwurf, wartet auf Freigabe durch Jo.

## Anlass

Zu jeder Probe sollen die Bedingungen am Fundort zum Fundzeitpunkt
festgehalten werden, damit sich Funddaten später zusammen mit Wetter und
Klima auswerten lassen (`docs/plan/wether-data.md`). Bei nachgetragenen
Proben sind das historische Daten.

Die Daten kommen vom Dienst **Tempus** (eigener Dienst, läuft bereits; in
diesem Dokument `https://tempus.example`). Tempus liefert zu Koordinate und
Zeitpunkt GeoJSON-Features für Wetter, Taupunkt, Sonne, Mond, Aggregate
(Niederschlag der Vortage, Tages-Extrema, Wärmesummen) und Klima (19
BIO-Variablen, Köppen-Geiger, Höhenstufe). Jedes Feature trägt einen
Lizenzblock.

Sonne und Mond werden heute im Backend selbst berechnet
(`tabularius/internal/astro`, pro Exkursion, immer in Europe/Berlin). Diese
Berechnung wird durch Tempus abgelöst.

## Ziele

- Jede Probe mit Koordinate hat Wetter, Klima, Sonne und Mond zu ihrem
  Zeitpunkt.
- Die Sample-Ansicht zeigt einen neuen Bereich „Wetter und Klima“ mit einer
  kompakten Auswahl und einer Detailseite mit allen Werten.
- Angereichert wird wie bei Ortus von zwei Seiten: die App holt die Daten,
  wenn sie online ist; sonst reichert das Backend an.
- Die vollständigen Tempus-Features bleiben zur Dokumentation als GeoJSON
  erhalten, samt Quellenangabe.
- Die eigene Astronomie-Berechnung entfällt.

## Nicht-Ziele

- Wetter für Exkursionen oder Fundorte als eigene Datensätze.
- Bearbeiten der Werte von Hand.
- Vorhersagen für geplante (zukünftige) Proben.
- Auswertungen, Diagramme, Filter nach Wetter.
- Änderungen am Tempus-Dienst.
- Feature-Flag (heute ist in der App nichts über Flags geschaltet).

## Anti-Ziele

- Die Anreicherung darf das Anlegen oder Speichern einer Probe nie
  blockieren oder scheitern lassen, weder in der App noch im Backend.
- Werte ohne Quellenangabe dürfen nicht angezeigt oder exportiert werden.
- Koordinaten dürfen nicht im Klartext in Logs landen (`LOGGING.md`).

## Jos Entscheidungen

- Die angezeigten Werte stehen als Felder in der Tabelle `samples`. Die
  einzelnen Tempus-Features werden zusätzlich als GeoJSON aufbewahrt.
- Die App holt die Daten, sofern Internet da ist. Wenn nicht, reichert der
  Server an.
- Abfragezeitpunkt ist immer der Beginn der Probe, als UTC an Tempus
  übergeben:
  - Probe mit Uhrzeit: der Beginn.
  - Ganztägige Probe: 14:00 Ortszeit des Sammeltags.
  - Ganztägige Probe einer Nachtexkursion (`fieldtrips.night_fieldtrip`):
    22:00 Ortszeit.
  - Ortszeit ist die Zeitzone der Probe (`samples.timezone`).
- Ganztägige Proben zeigen in der Ansicht nur Tageswerte (siehe unten).
  Gespeichert wird trotzdem alles, was die Abfrage liefert.
- Die Ansicht zeigt eine kompakte Auswahl, alles Übrige steht auf einer
  Detailseite.
- Sonne und Mond kommen pro Sample aus Tempus. Das Astro-Panel der
  Exkursion wird entfernt.
- Zeitangaben von Tempus (UTC) rechnet die App in die Zeitzone der Probe
  um.

## Ausgangslage im Code

- **Ortus-Muster Backend:** `tabularius/internal/services/ortus.go`
  (Wrapper mit Retry, Timeout, `geocache` 7 Tage),
  `internal/enrichment/enrichment.go` (asynchron in Goroutine mit Recover
  nach `OnRecordCreateRequest`/`OnRecordUpdateRequest` auf `samples`),
  `internal/hooks/sample_location.go` (setzt den Status zurück, wenn sich
  die Koordinate ändert und der Client nichts Neues mitschickt).
- **Ortus-Muster App:** `Core/Ortus/OrtusClient.swift` (5 s Timeout,
  Endpoint aus `AppConfig`, in den Einstellungen änderbar),
  `Core/Geo/SampleLocationResolver.swift` (schreibt Probe und Features
  lokal, reiht ein Update ein), `SyncRunner` (schiebt Features hoch, pollt
  nach dem Push kurz auf die Backend-Anreicherung, übernimmt die
  Serverkopie).
- **Features:** Collection `sample_features` (`source_id`, `source_name`,
  `layer`, `feature_id`, `properties`, `license`, `fetched_at`), lokal
  `local_sample_features`. Achtung: `geoplace.ReplaceFeatures`,
  `PUT /api/samples/{id}/features` und `LocalSampleFeatureStore.replace`
  löschen heute **alle** Features einer Probe, ohne Filter auf die Quelle.
- **Astronomie:** `internal/astro` schreibt `fieldtrips.astro` (JSON).
  Verbraucher in der App: `AstroPanel`, `FieldtripDetailView`,
  `SampleEditorView` (Sonnenauf-/-untergang in der Zeitzeile), Modell
  `Fieldtrip.Astro`. Im Backend nur der generische Export.

## Was Tempus vorgibt

- `GET /api/v1/query?lat&lon&elevation&datetime` liefert bei gültiger
  Anfrage HTTP 200. Der Zustand
  je Provider steht in `providers[]`: `ok`, `unavailable` (erneut
  versuchen, `retryAfter` als Go-Dauer wie `2h0m0s`) oder `error` (nicht
  erneut versuchen).
- `elevation` ist Pflicht (Nachtrag 2026-11-21, siehe „Höhe als
  Voraussetzung“): Höhe des Ortes in Metern über dem Meer (orthometrisch,
  also aus Karte, DEM oder MSL-Höhe des GNSS-Empfängers), Bereich −500 bis
  9000. Sie wählt die Gitterzelle und korrigiert Temperatur und Taupunkt.
  Tempus unterscheidet ganze Meter. Ohne oder mit ungültiger Höhe kommt
  HTTP 400.
- Der Zeitpunkt wird auf die volle UTC-Stunde abgerundet.
- Für Zeitpunkte, die jünger als etwa 5 Tage sind, kommen Vorhersagedaten.
  Danach liefert dieselbe Abfrage endgültige Archivdaten (ERA5). Für die
  letzten Stunden kann Wetter `unavailable` sein.
- Zukünftige Zeitpunkte: Wetter und Aggregate melden `error`, Sonne und
  Mond funktionieren.
- Keine Authentifizierung. Clients sollen unbekannte Properties ignorieren.
- Batch-Endpunkt `POST /api/v1/query/batch` mit Tagesbudget für die
  dahinterliegende Wetterquelle (Klima ist am teuersten).

## Datenhaltung

### Felder an `samples` (Backend-Migration, lokal GRDB-Migration)

| Feld | Inhalt |
|---|---|
| `conditions_status` | leer, `pending`, `provisional`, `final` |
| `conditions_retry_at` | frühester Zeitpunkt der nächsten Abfrage (nur bei `provisional`) |
| `conditions_fields` | Liste der Wertfelder, die Tempus tatsächlich geliefert hat, z.B. `["sunrise","weather_temperature_c"]` |
| `conditions_queried_for` | UTC-Zeitpunkt, mit dem Tempus gefragt wurde |
| `conditions_fetched_at` | wann die Antwort geholt wurde |
| `weather_temperature_c` | Temperatur 2 m |
| `weather_humidity_pct` | relative Luftfeuchte |
| `weather_dew_point_c` | Taupunkt |
| `weather_precipitation_mm` | Niederschlag der Stunde |
| `weather_wind_speed_kmh` | Wind 10 m |
| `weather_cloud_cover_pct` | Bewölkung |
| `weather_code` | WMO-Code |
| `precipitation_24h_mm`, `_72h_mm`, `_120h_mm` | Niederschlag der Vortage |
| `day_temperature_min_c`, `_max_c`, `_mean_c` | Tages-Extrema |
| `climate_koppen_code` | Köppen-Geiger-Code |
| `climate_altitudinal_belt` | Höhenstufe (deutsche Bezeichnung) |
| `sunrise`, `sunset` | UTC-Zeitpunkte |
| `moon_phase` | Mondphase (deutsche Bezeichnung) |
| `moon_illumination_pct` | beleuchteter Anteil |

Die Feldnamen sind mein Vorschlag. Alle Wertfelder sind optional.

Zahlenfelder kennen in PocketBase kein „leer“, ein fehlender Wert steht als
0 in der Spalte. 0 °C oder 0 mm sind aber echte Werte. Deshalb listet
`conditions_fields` genau die Wertfelder, die Tempus geliefert hat: eine
Spalte gilt nur, wenn ihr Name in der Liste steht. Das gilt feldgenau, auch
wenn innerhalb eines gelieferten Features ein einzelner Wert fehlt (oder
der Wind in einer anderen Einheit als km/h kommt). App und Export müssen
diese Regel beachten.

Statusbedeutung (mein Vorschlag, Tempus meldet den Zustand je Provider):

- leer: noch nie verarbeitet. Gilt für alle Proben, die vor PR 7 angelegt
  wurden; die Migration setzt nichts. Der Nachzieh-Job fasst sie nicht an,
  sie werden nur vom Backfill (PR 9) gefüllt. Die Ansicht zeigt für sie
  „Noch keine Wetterdaten“.
- `pending`: neue oder geänderte Probe mit Koordinate, noch keine Antwort
  von Tempus. Wertfelder sind leer.
- `provisional`: Es gab eine Antwort, aber sie ist nicht endgültig, weil
  mindestens eines zutrifft: ein Provider meldet `unavailable`, der
  Abfragezeitpunkt war beim Abruf jünger als 5 Tage, oder er liegt in der
  Zukunft.
- `final`: Antwort liegt vor, der Abfragezeitpunkt war beim Abruf
  mindestens 5 Tage alt und kein Provider meldet `unavailable`. Provider
  mit `error` gelten als endgültig ohne Daten.

Regeln dazu:

- Jede Antwort wird teilweise übernommen: Features und Werte aller
  Provider mit `ok` werden gespeichert, auch wenn andere fehlen. Sonne und
  Mond liegen damit immer sofort vor, auch bei Zeitpunkten in der Zukunft.
- `conditions_retry_at` ist der späteste der gemeldeten `retryAfter`-Werte,
  sonst Abfragezeitpunkt plus 5 Tage, bei Zukunft der Abfragezeitpunkt
  plus eine Stunde.
- „Keine Daten für diesen Zeitpunkt“ zeigt die Ansicht, wenn der Status
  `final` ist und die Wetterwerte fehlen. Einen eigenen Status dafür gibt
  es nicht.

### GeoJSON-Features

Die vollständigen Features liegen in der bestehenden Collection
`sample_features` (lokal `local_sample_features`), eine Zeile pro
Tempus-Feature, `source_id` mit Präfix `tempus:` plus Art (`tempus:weather`,
`tempus:dewpoint`, `tempus:sun`, `tempus:moon`, `tempus:aggregate`,
`tempus:bioclim`), `properties` und `license` unverändert aus der Antwort
(mein Vorschlag; Alternative wäre eine eigene Collection gewesen).

Dafür muss das Ersetzen von Features an allen drei Stellen quellenbezogen
werden: Ortus ersetzt nur Ortus-Zeilen, Tempus nur `tempus:`-Zeilen. Das
ist Voraussetzung und wird mit Tests abgesichert, die zeigen, dass ein
Ortus-Lauf Tempus-Zeilen stehen lässt und umgekehrt.

## Ablauf

### Abfragezeitpunkt

Eine pure Funktion in `tabularius/internal/` (mit Tests, > 80 % Coverage)
und ihr Gegenstück in der App berechnen aus Beginn, Zeitzone, Ganztägig und
Nachtexkursion den UTC-Abfragezeitpunkt nach Jos Regel oben. Die App
dupliziert diese Regel, weil sie offline-nah selbst abfragt; das ist die
einzige duplizierte Logik.

Kennt die App die Exkursion einer neuen ganztägigen Probe noch nicht, nimmt
sie 14:00. Ändert sich der Abfragezeitpunkt später (z.B. weil das Backend
die Exkursion als Nachtexkursion einstuft), gilt das als Änderung und das
Backend fragt neu ab.

### Höhe als Voraussetzung (Nachtrag 2026-11-21)

Tempus liest das Wetter inzwischen direkt aus den Reanalyse-Daten und
verlangt dafür die Höhe des Ortes. Eine Probe kann deshalb erst abgefragt
werden, wenn sie eine Höhe hat. Maßgeblich ist das Feld `elevation` der
Probe mit seiner Herkunft `elevation_source`:

- `location_service`: Höhe aus dem GPS-Empfänger (iOS liefert sie über dem
  Meer). Sie ist mit dem Fix da, die App kann sofort abfragen.
- `backend_service`: DEM-Höhe von Ortus. Sie kommt mit der Ortus-Antwort,
  in der App wie im Backend.
- `manual`: von Hand eingetragen.

Welche Höhe an der Probe steht, regelt weiterhin Phase O: Eine GPS- oder
Hand-Höhe wird nie durch die DEM-Höhe ersetzt. Tempus bekommt, was an der
Probe steht, gerundet auf ganze Meter.

Daraus folgt:

- Eine Probe mit Koordinate, aber ohne Höhe (leere `elevation_source`)
  oder mit einer Höhe außerhalb des Bereichs wird nicht abgefragt. Ihr
  Status bleibt `pending`, bis eine Höhe da ist. Im Backend fragt der
  Ortus-Lauf danach selbst an; der stündliche Job fasst Proben ohne Höhe
  nicht an.
- Die Werte gelten für die Höhe, mit der gefragt wurde. Ändert sich die
  Höhe um mindestens einen ganzen Meter, gilt das wie eine verschobene
  Koordinate: Werte leeren, Status `pending`, neu abfragen. Das gilt auch,
  wenn der Ortus-Lauf eine DEM-Höhe ersetzt.
- Eine DEM-Höhe gehört zur Koordinate, für die sie gelesen wurde. Wird die
  Koordinate einer Probe mit DEM-Höhe verschoben, fragt das Backend nicht
  sofort, sondern erst nach dem Ortus-Lauf, den dieselbe Änderung auslöst
  und der die Höhe ersetzt oder bestätigt. Scheitert der Ortus-Lauf, wird
  mit der bisherigen DEM-Höhe gefragt; ein späterer Lauf mit anderer Höhe
  setzt die Werte wieder zurück.
- Hat eine wartende Probe keine nutzbare Höhe, werden auch ihre
  Tempus-Features entfernt.
- Vom Client mitgeschickte Werte werden nur übernommen, wenn die Probe eine
  nutzbare Höhe hat.
- Der Cache-Schlüssel im Backend enthält die Höhe in ganzen Metern.
- Der Backfill und der stündliche Job wählen nur Proben mit nutzbarer
  Höhe aus, damit übersprungene Proben nicht das Limit verbrauchen. Der
  Backfill meldet die Zahl der Altproben ohne nutzbare Höhe getrennt; für sie muss zuerst der Ortus-Backfill laufen.

### App

- Die App fragt erst ab, wenn die Probe eine Höhe hat: sofort mit der
  GPS-Höhe, sonst nach der Ortus-Antwort mit der DEM-Höhe. Ohne Höhe
  bleibt der Status `pending`.
- Nach dem Anlegen einer Probe mit Koordinate, nach einer Änderung von
  Koordinate, Beginn, Zeitzone oder Ganztägig und beim Nachtragen fragt die
  App Tempus direkt ab, wenn sie online ist. Reihenfolge: erst lokal
  speichern, dann abfragen; die Abfrage läuft im Hintergrund und hat ein
  kurzes Timeout wie bei Ortus.
- Erfolg: Werte und Features werden lokal geschrieben, der Status gesetzt,
  und die Änderung geht über die Sync-Queue ans Backend (Werte mit der
  Probe, Features wie bei Ortus).
- Kein Netz, Timeout oder Fehler: Status bleibt `pending`, die Probe wird
  ohne Werte gesynct, das Backend übernimmt.
- Der Tempus-Endpoint kommt aus `AppConfig` und ist in den Einstellungen
  änderbar, analog zum Ortus-Endpoint. Die echte Adresse steht wie bei
  Ortus als Default in `AppConfig` und in den Compose-Dateien (Jos
  Entscheidung); in Doku, Specs und Commit-Texten steht nur der
  Platzhalter. Tempus braucht keine Authentifizierung.
- Proben ohne Koordinate werden nicht abgefragt.

### Backend

- Neuer Wrapper `internal/services/tempus.go` nach dem Vorbild von
  `ortus.go`: Retry, Timeout, Cache in `geocache` (Schlüssel aus
  Koordinate, Höhe und Abfragezeitpunkt; endgültige Antworten 7 Tage,
  vorläufige höchstens 1 Stunde). Endpoint aus `TEMPUS_BASE_URL`
  (Docker-Compose, mit Default wie bei `ORTUS_BASE_URL`). Ist die Variable
  ausdrücklich leer, läuft das Backend ohne Tempus und loggt eine Warnung.
- Anreicherung asynchron in einer Goroutine mit Recover, nie direkt im
  Hook:
  - nach dem Anlegen, wenn die Probe eine Koordinate hat und der Client
    keine Werte mitgeschickt hat (`conditions_status` ist `pending`);
  - nach einem Update, wenn sich Koordinate oder Abfragezeitpunkt geändert
    haben und der Client keine dazu passenden neuen Werte mitgeschickt hat.
    Ein Hook setzt den Status dann zurück auf `pending` und leert die
    Wertfelder (Vorbild `sample_location.go`).
- Die Anreicherung schreibt Werte, Status und Features und erhöht die
  `version` der Probe nur, wenn sich etwas geändert hat. Die App übernimmt
  das über den bestehenden Poll nach dem Push bzw. den nächsten Pull.
- **Nachziehen:** Ein stündlicher Job fragt erneut ab: Proben mit Status
  `provisional`, deren `conditions_retry_at` erreicht ist, und Proben mit
  Status `pending`, Koordinate und Höhe, die älter als eine Stunde sind (z.B.
  weil Tempus nicht erreichbar war). Damit bekommt eine frische Probe, für
  deren letzte Stunden noch kein Wetter vorlag, ihre Werte nach wenigen
  Stunden und die endgültigen nach 5 Tagen. Der Job überschreibt Werte,
  auch wenn sie ursprünglich von der App kamen. Er ist in der Zahl der
  Abfragen pro Lauf begrenzt und fasst Proben mit leerem Status nicht an.
- Die App fragt nicht von sich aus nach; nachgezogene Werte kommen über
  den normalen Pull.
- Logging nach `LOGGING.md`: `service=tempus`, `sample_id`, `cache`,
  `duration_ms`, Statuscode, keine Koordinaten.

### Wer gewinnt

- Liefert die App passende Werte (gleiche Koordinate, gleicher
  Abfragezeitpunkt), übernimmt das Backend sie und fragt nicht selbst.
  Status und Zeitpunkt der nächsten Abfrage leitet das Backend dabei aus
  dem Abfragezeitpunkt und dem Abrufdatum der App ab; ohne Abrufdatum
  gelten die Werte als nicht geliefert.
- Der Nachzieh-Job des Backends darf Werte der App überschreiben, weil die
  Werte nicht von Hand bearbeitet werden und endgültige Daten vorläufige
  ersetzen sollen.
- Hat die App lokal noch eine ungesendete Änderung an der Probe, gilt die
  bestehende Konfliktregel (409 → Serverkopie übernehmen, erneut senden);
  die Wetterfelder kommen dabei vom Server.

## Ansicht

Neuer Bereich in `SampleEditorView` unter „Standort und Zeit“, vor der
Karte. Skizze für eine Probe mit Uhrzeit:

```
WETTER UND KLIMA                                  vorläufig
 ☀︎  Klar                                   18,4 °C
     Luftfeuchte 62 %   Taupunkt 11,0 °C
     Wind 9 km/h        Bewölkung 10 %
     Niederschlag 0,0 mm
     Vortage: 2,1 mm (24 h) · 8,4 mm (72 h) · 8,4 mm (120 h)
     Tag: 9,2 – 21,7 °C
 ☾  Zunehmender Mond, 43 %
     Sonnenaufgang 07:31   Sonnenuntergang 16:28
 ▲  Cfb · Submontane Stufe
     Quellen: Open-Meteo.com, ERA5 …               Details ›
```

- Wetter-Symbol und Text aus dem WMO-Code (SF Symbols, Text aus dem
  Feature). Status nie nur über Farbe.
- **Ganztägige Probe:** nur Tageswerte: Tag (Min/Max/Mittel), Vortage,
  Mond, Sonnenauf-/-untergang, Klima. Keine Stundenwerte (Temperatur,
  Luftfeuchte, Taupunkt, Wind, Bewölkung, Niederschlag der Stunde,
  Wetter-Symbol).
- Sonnenauf-/-untergang ziehen aus der Zeitzeile in diesen Bereich um und
  werden in der Zeitzone der Probe angezeigt.
- Zustände: „Wird ermittelt …“ (`pending`), „Ohne Koordinate keine
  Wetterdaten“, „Noch keine Wetterdaten“ (leerer Status), „Keine Daten für
  diesen Zeitpunkt“ (`final` ohne Wetterwerte), Kennzeichnung „vorläufig“
  (`provisional`). Vorhandene Teilwerte werden immer gezeigt.
- Quellenangabe: die `attribution`-Texte der angezeigten Features, ohne
  Dopplungen, immer sichtbar, wenn Werte sichtbar sind.
- **Detailseite** (Push): alle Features gruppiert nach Wetter, Aggregate
  (inkl. Wärmesummen), Klima (19 BIO-Variablen, Köppen, Höhenstufe mit
  Indikatoren), Sonne (inkl. Dämmerungen, Tageslänge), Mond; je Gruppe
  Quelle mit Lizenzname und Link, dazu Abfragezeitpunkt und Abrufdatum.
  Sie liest aus den gespeicherten Features, unbekannte Properties werden
  generisch als Name/Wert gezeigt.
- A11y nach `ACCESSIBILITY-IOS.md`: Wertepaare stapeln sich bei großen
  Schriften (`ViewThatFits`), Zeilen sind sinnvoll kombinierte
  VoiceOver-Elemente mit ausgeschriebenen Einheiten, Überschriften als
  Header markiert. Aufbau nur aus Tokens und Atoms; die Wertepaar-Zeile
  wird bei der dritten Wiederholung ein Atom in `Core/UI/`.
- Zahlen im UI im deutschen Format (Dezimalkomma).

## Ablösung der eigenen Astronomie

- Entfällt: `tabularius/internal/astro`, der Astro-Teil von
  `recomputeFieldtripDerived` (Schwerpunkt, `day_of_year` und
  Fundort-Vorschlag bleiben), das Feld `fieldtrips.astro` (Migration),
  in der App `AstroPanel`, der Astro-Teil von `FieldtripDetailView`,
  `Fieldtrip.Astro` und die Verwendung in `SampleEditorView`.
- Neues ADR, das `docs/adr/0001-astro-eigenbau.md` ablöst.
- `night_fieldtrip` bleibt (wird aus den Probenzeiten abgeleitet, nicht aus
  der Astronomie).
- Bekannte Einschränkung, bewusst hingenommen: Tempus bestimmt Auf- und
  Untergang für den UTC-Kalendertag des Abfragezeitpunkts. Weit entfernt
  von Greenwich kann einer der beiden Zeitpunkte zum benachbarten lokalen
  Tag gehören. Die angezeigte Uhrzeit weicht dann um wenige Minuten ab.
- Bekannte Einschränkung: Tempus kennt die Höhe des Fundorts nicht.
  Temperatur und Klima gelten für die Rasterzelle der Wetterquelle. Die
  Detailseite nennt das in einem Satz.

## Ansätze

Für die Datenhaltung standen drei Wege zur Wahl:

| Weg | Vorteil | Nachteil |
|---|---|---|
| Eigene Collection für Tempus-Features | eigener Lebenszyklus, kein Umbau bei Ortus | Werte nicht direkt an der Probe, neue Tabelle in Backend und App |
| Bestehende `sample_features` mitbenutzen | keine neue Tabelle | Ersetzen muss quellenbezogen werden |
| JSON-Feld an der Probe | am wenigsten Code | Werte nicht einzeln abfragbar |

Jo hat entschieden: Werte als Felder an `samples`, Features zusätzlich als
GeoJSON. Für das GeoJSON nutze ich `sample_features` (mein Vorschlag),
weil dort Lizenz, Export und Sync schon vorhanden sind.

Für die Rollenverteilung standen „App nur Vorschau, Backend maßgeblich“
und „wie Ortus“ zur Wahl. Jo hat das Ortus-Muster gewählt: die App liefert,
wenn sie kann, sonst das Backend.

## Reihenfolge und PRs

Die Backend-PRs 7 und 9 hängen nicht an der Sample-Ansicht und gehen von
`main` ab (9 auf 7). PR 8 baut auf PR 7 auf und beginnt erst, wenn die PRs
1 bis 6 aus `2026-11-18-sample-ansicht-design.md` gemerged sind, weil er
dieselbe Ansicht umbaut. PR 10 baut auf PR 8 auf.

| PR | Branch | Inhalt |
|---|---|---|
| 7 | `feat/tempus-backend` | Migration, Wrapper, Abfragezeitpunkt, Anreicherung, Nachzieh-Job, quellenbezogenes Ersetzen der Features |
| 8 | `feat/tempus-ios` | Client, lokale Felder und Features, Sync, Bereich „Wetter und Klima“, Detailseite, Endpoint in den Einstellungen |
| 9 | `feat/tempus-backfill` | Kommando, das bestehende Proben nachfüllt (Batch-Endpunkt, über Tage verteilt wegen des Tagesbudgets, wiederaufsetzbar) |
| 10 | `feat/astro-aus-tempus` | Ablösung der eigenen Astronomie, ADR |

PR 10 wird erst gemerged, wenn der Backfill auf den Zielumgebungen
gelaufen ist, damit bestehende Proben ihre Sonnen- und Monddaten nicht
verlieren. `PHASES.md` bekommt mit PR 7 einen eigenen Abschnitt.

## Prüfung

- Backend: `go test ./...`; Tests für den Abfragezeitpunkt (Uhrzeit,
  ganztägig, Nachtexkursion, Zeitzonen, Sommerzeit), den Wrapper gegen
  aufgezeichnete Tempus-Antworten (`ok`, `unavailable` mit `retryAfter`,
  `error`, unbekannte Properties), die Anreicherung (App hat geliefert /
  nicht geliefert / Koordinate oder Zeit geändert), den Nachzieh-Job und
  das quellenbezogene Ersetzen.
- iOS: `bash scripts/check-ios.sh`; Unit-Tests für Abfragezeitpunkt,
  Dekodierung, lokale Speicherung und Sync; Anti-Pattern-Greps aus
  `ACCESSIBILITY-IOS.md` und `DESIGN-SYSTEM.md`.
- Von Hand durch Jo: neue Probe online, neue Probe offline (Werte kommen
  nach dem Sync), ganztägige Probe, nachgetragene Probe mit altem Datum,
  AX5 und VoiceOver im neuen Bereich.

## Dem Umsetzer überlassen

- Aufbau der Go- und Swift-Typen für die Tempus-Antwort.
- Genaue Cache-Schlüssel und TTLs im Rahmen der Vorgaben oben.
- Technik des täglichen Jobs (PocketBase-Cron) und seine Begrenzung.
- Auswahl der SF Symbols für WMO-Codes.
- Ob die lokale Spalte `astro_json` per GRDB-Migration entfernt wird oder
  ungenutzt bleibt.
