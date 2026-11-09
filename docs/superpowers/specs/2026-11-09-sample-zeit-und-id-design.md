# Sample: Zeitzone, Zeitfenster, Sample-ID und Höhe — Design

Stand: 2026-11-09 · Branch-Basis: `feat/ortus-sample-ort` (nach Abschluss Phase O2)

Eigene Phase nach O2. O2 wartet noch auf Jos Test (Task 18) — nicht vermischen.

## Warum

1. Zeiten werden heute fest in `Europe/Berlin` gerechnet und angezeigt. Wer auf La Palma
   oder in Griechenland sammelt, sieht falsche Uhrzeiten, und der Sammeltag (Rollover)
   stimmt nicht. Ortus liefert die an der Koordinate gültige Zeitzone (`timezones-2026a`).
2. Das Sample-ID-Format `<YY><MM><DD>/<seq>` und der Rollover 5:00 sind Jos persönliche
   Präferenzen, keine allgemeinen Regeln. Andere User nummerieren nach ganz anderer
   Logik. Die ID ist das, was auf dem Röhrchen steht — sie gehört dem User.

## Ziele

- Zeiten werden immer in UTC gespeichert, aber in der Ortszeit des Samples eingegeben
  und angezeigt.
- Jedes Sample trägt seine Zeitzone (IANA) im Feld `timezone`.
- Beginn und Ende werden beim Anlegen sofort gesetzt.
- Der User bestimmt Format, Präfix, Zähler und Rollover in den Einstellungen.
- Die Sample-ID wird nach dem Speichern weder von App noch Backend verändert — einzige
  Ausnahme: der Konfliktsuffix bei versehentlich doppelter Vergabe (siehe unten).

## Nicht-Ziele

- Manuelles Nachtragen von Samples mit Ortszeit + Koordinate (Jo hat dafür eigene
  Änderungen angekündigt).
- Umzug eines Samples in eine andere Exkursion, wenn Ortus nachträglich eine andere
  Zeitzone liefert.
- Speicherung des `timezones-2026a`-Features als Sample-Feature.

## Anti-Ziele (wäre ein Fehlschlag, auch wenn es technisch läuft)

- App oder Backend überschreibt/nummeriert eine gespeicherte Sample-ID um.
- Eine Konvention eines Users wird anderen untergeschoben (fest verdrahtete 5:00 oder
  Europe/Berlin irgendwo in der Rechenlogik).
- Uhrzeiten werden in der aktuellen Gerätezeitzone angezeigt, obwohl das Sample eine
  bekannte, andere Zeitzone hat.

## 1. Zeitzone

### Feld

- `samples.time_zone` wird umbenannt in **`timezone`** (Backend-Migration, iOS-GRDB-
  Migration, Sync-Mapping, Codable-Keys). Wert: IANA-Kennung, z. B. `Atlantic/Canary`.
- Bestehende Werte bleiben erhalten (Altbestand hat `Europe/Berlin`).

### Herkunft

- **Beim Anlegen:** die Zeitzone des Geräts (`TimeZone.current.identifier`). Im Feld
  stimmt sie in der Praxis. Steht das iPhone falsch, ist das Sache des Users — er sieht
  es in allen Apps so.
- **Ortus:** Die Quelle `timezones-2026a` liefert `features[0].properties.tzid`
  (verifiziert gegen `https://ortus.fieldworksdiary.org`, 49.70/10.05 → `Europe/Berlin`).
  Sobald sie vorliegt, wird `timezone` damit gesetzt — sowohl in der App
  (`SampleLocationResolver`) als auch in der Backend-Anreicherung.
- **Manuell:** Im Bearbeiten-Dialog wählbar (siehe 1.4). Eine manuell gewählte
  Zeitzone wird von Ortus nicht mehr überschrieben (gleiche Logik wie bei den
  Ortsangaben). Dafür gibt es eine Quellenangabe `timezone_source`
  (`device` | `location_service` | `manual`) — Name/Werte sind Builder-Entscheidung,
  solange sie zu den bestehenden `*_source`-Feldern passen.
- Das Feature `timezones-2026a` wird **nicht** in `sample_features` übernommen — weder
  im Go-Mapping (`internal/geoplace`) noch im Swift-`OrtusMapper`.
- Eine nachträglich gelieferte Zeitzone ändert **nicht** Sammeltag, Exkursion oder
  Sample-ID. Sie wirkt nur auf Anzeige und Eingabe. Erweist sich das später als Problem,
  wird es dann geändert.

### Anzeige

- Alle Datums-/Zeitangaben eines Samples (Liste, Detail, Bearbeiten) werden in
  `sample.timezone` dargestellt — auch wenn das Gerät später in einer ganz anderen
  Zone steht.
- Unter dem Datum in der Sample-Ansicht steht die **für dieses Sample zum Beginn-Zeitpunkt
  gültige** Zeitzone, z. B. „Atlantic/Canary (WET)“ im Winter und „Atlantic/Canary (WEST)“
  im Sommer — Abkürzung abhängig vom Datum, nicht statisch.
- Eingabe im Bearbeiten-Dialog: DatePicker mit `timeZone = sample.timezone`.

### Manuelle Zeitzonenwahl (Bearbeiten)

- Vorbild: Alt-App `../fieldworksdiary/` (`TimeZonePickerController`,
  `TimeZonesController`): erst Region wählen (Präfix der IANA-Kennung: Europe, Atlantic,
  America, …), dann die Zone aus `TimeZone.knownTimeZoneIdentifiers` dieser Region,
  alphabetisch. Die aktuelle Zone ist markiert.
- Beim Wechsel der Zeitzone bleibt der UTC-Zeitpunkt gleich; nur die Anzeige verschiebt
  sich.

## 2. Zeitfenster beim Anlegen

- `is_all_day = false` (Default, bleibt).
- `begin_date` = Erstellzeitpunkt, **abgerundet auf die Viertelstunde** in der
  Ortszeit des Samples: 12:03:43 → 12:00:00, 12:29:59 → 12:15:00. (Bei Zonen mit
  :30/:45-Offset wird in der Ortszeit gerundet, nicht in UTC.)
- `end_date` = `begin_date` + 15 min, **sofort mitgespeichert** (heute `nil`).
- Beides UTC. Der User passt es bei Bedarf im Bearbeiten-Dialog an.

## 3. Sammeltag und Tagesrollover

- Neue Einstellung **Tagesrollover**, ganze Stunden 0–23, **Default 0:00**.
  (Jo stellt für sich 5:00 ein.)
- Der Rollover gilt in **Ortszeit des Samples** — für jedes Sample in dessen Zeitzone
  (beim Anlegen = Gerätezeitzone).
- Sammeltag und Exkursionszuordnung werden **einmal beim Anlegen** festgelegt und danach
  nicht neu bewertet.
- Speicherort: am User im Backend (`users.day_cutoff_hour`, Feldname nach Kommentar in
  `backend/internal/hooks/sample_create.go`), synchronisiert, weil das Backend die
  Exkursionen zuordnet. Die App cached den Wert lokal für den Offline-Betrieb.
- Backend: `processSample` rechnet heute fest mit `Europe/Berlin` und `defaultCutoff = 5`.
  Künftig: Zeitzone aus dem Sample-Record (`timezone`), Rollover aus dem User. Fehlt
  `timezone` (Altclient), nimmt das Backend `Europe/Berlin` (Bestandsverhalten); fehlt
  der Rollover am User, gilt 0.
- iOS: `LocalSampleStore` und `HomeViewModel` lesen Rollover aus den Einstellungen statt
  der Konstante 5 bzw. Zeitzone `Europe/Berlin`.

## 4. Sample-ID

### Grundregel

Die Sample-ID ist das, was beim Speichern im Feld steht. App und Backend verändern sie
danach nie. Der User darf sie jederzeit selbst ändern. Format und Zähler sind nur ein
**Vorschlag**, mit dem das Feld beim Anlegen vorbelegt wird.

### Einstellungen

- **Format** (Vorlage) aus Bausteinen:
  - `<PREFIX>` — fester Präfix (Text aus der Einstellung „Präfix“)
  - `<YYYY>` `<YY>` `<MM>` `<DD>` — Sammeltag
  - `<seq>` — Tagessequenz (beginnt jeden Sammeltag bei 1)
  - `<n>` — laufende Nummer (zählt immer weiter)
  - „–“ (leer lassen) — kein Vorschlag, Feld bleibt leer
- Ein Format enthält **höchstens einen** der beiden Zähler (`<seq>` oder `<n>`).
  Die Einstellungen lassen nur gültige Formate zu.
- **Präfix:** freier Text, z. B. „JB-“.
- **Offset** für die laufende Nummer: Startwert. Offset 1000 → erster Vorschlag 1001.
- **Default:** `<YY><MM><DD>/<seq>` (wie bisher), Präfix leer, Offset 0.
- Presets in den Einstellungen: mindestens der Default, `<PREFIX><n>`, „–“; die
  bestehenden Presets bleiben.
- Speicherort: am User im Backend (wie Rollover) und lokal gecacht.

### Zähler

- **Tagessequenz:** nächste Nummer pro (User, Sammeltag) — wie heute.
- **Laufende Nummer:** pro User; nächster Vorschlag = max(höchste bisher vorgeschlagene
  laufende Nummer, Offset) + 1. Manuell geänderte IDs beeinflussen den Zähler nicht.
  Wird der Offset über den aktuellen Stand gesetzt, springt der Zähler dorthin.
- Beide Zähler laufen offline in der App. Wechselt der User das Format, entsteht ein
  Mix verschiedener Schemata — das ist erlaubt.

### Eindeutigkeit

- Eine Sample-ID muss **pro User** eindeutig sein (heute prüft das Backend fälschlich
  über alle User).
- Leere IDs (Format „–“, noch nicht ausgefüllt) sind von der Eindeutigkeit ausgenommen.
- **App:** Beim Speichern (Anlegen und Bearbeiten) prüft sie gegen die lokalen Samples
  des Users und meldet „Diese Sample-ID ist bereits vergeben.“ — Speichern erst nach
  Korrektur.
- **Backend:** ein Unique-Index auf `(owner, sample_id)` für nicht-leere IDs (partieller
  Index). Achtung: PocketBase leitet aus UNIQUE-Indizes Formvalidatoren ab, die vor dem
  Hook greifen (siehe Kommentar in Migration `1700000017`) — der Builder muss sicherstellen,
  dass der Konfliktsuffix trotzdem gesetzt werden kann (z. B. Suffix im Before-Hook
  vor der Validierung, oder Index ohne Form-Validator).

### Einzige Ausnahme: Konfliktsuffix

- Wurde dieselbe ID versehentlich doppelt vergeben (offline, ein oder zwei Geräte),
  hängt das Backend beim Sync an die später eintreffende ID eine Nummer in Klammern:
  `250611/3` → `250611/3 (2)`, bei weiterem Konflikt `(3)` usw. Der Rest bleibt
  unverändert.
- Das bisherige Umnummerieren (`codes.FormatCode` + `original_code`) entfällt. Ebenso
  vergibt das Backend bei leerer ID **keinen** Code mehr.
- Die App übernimmt die Server-ID beim Sync und kennzeichnet betroffene Samples sichtbar
  („ID doppelt vergeben — bitte prüfen“), damit der User korrigieren kann. Wie die
  Kennzeichnung aussieht und wie sie verschwindet (z. B. sobald der User die ID ändert),
  entscheidet der Builder.
- `sample_sequences` wird beim Übernehmen einer Client-ID weiterhin hochgezogen, wenn
  sie einen erkennbaren Tageszähler enthält — das ist Zählerpflege, keine Änderung der ID.

## 5. Höhe: nur noch ein Wert

Bisher gibt es zwei Höhen am Sample (`elevation` und den DEM-Referenzwert
`elevation_dem`/`elevation_dem_accuracy`). Das ist mehrdeutig und entfällt.

- Am Sample gibt es genau **`elevation`** (m) mit **`vertical_accuracy`** (m, Fehler) und
  **`elevation_source`** (`location_service` | `backend_service` | `manual`).
- **Herkunft:**
  - GPS liefert im Feld eine Höhe → `elevation` + `vertical_accuracy` vom Gerät,
    Quelle `location_service`.
  - Kommt vom Gerät keine Höhe, liefert Ortus sie (DEM): `gazetteer.elevation.meters`
    → `elevation`, `accuracy_m` → `vertical_accuracy`, Quelle `backend_service`.
    Gilt in App (`SampleLocationResolver`) und Backend-Anreicherung gleichermaßen.
  - Trägt der User eine Höhe ein oder ändert eine vorhandene (egal welcher Herkunft),
    wird die Quelle `manual`. Den Fehler kann er eintragen, muss aber nicht; ohne Eingabe
    bleibt `vertical_accuracy` leer. Der Fehler der vorherigen Herkunft wird dabei
    verworfen, weil er zur neuen Höhe nicht mehr passt *(Entscheidung Claude)*.
- GPS- und manuelle Höhen werden nie durch Ortus ersetzt, auch nicht nach einer
  Koordinatenkorrektur. Eine `backend_service`-Höhe wird bei Koordinatenkorrektur neu
  bestimmt (bestehende Regel „Korrektur leert abgeleitete Werte“).
- **`elevation_source` ist reines Metadatum** für den späteren Datenexport. Die UI zeigt
  sie nicht mehr an (heute: `SampleEditorView.elevationSourceText`). `vertical_accuracy`
  wird wie bisher angezeigt („± 4 m“), wenn bekannt.
- **„Höhe vorhanden“** heißt `elevation_source` ist gesetzt — nicht `elevation != 0`,
  denn 0 m (Meeresniveau) ist eine gültige Höhe. Leerer `vertical_accuracy` = unbekannt
  (PocketBase speichert 0; ein Fehler von 0 m kommt real nicht vor).
  *(Entscheidung Claude)*
- **Spalten entfallen:** `samples.elevation_dem`, `samples.elevation_dem_accuracy`
  (Backend-Migration, iOS-GRDB-Migration, Modelle, Sync, Mapping in `internal/geoplace`
  und `FieldworksGeo`).
- **Bestandsdaten:** Hat ein Sample keine Höhe, aber einen DEM-Wert, wandert dieser vor
  dem Löschen nach `elevation`/`vertical_accuracy` mit Quelle `backend_service`.
  Lokal betrifft das aktuell 0 von 15 Samples; die Migration ist trotzdem nötig für Prod.
- Localities (`altitude`, `vertical_accuracy`) sind nicht Teil dieser Änderung.

## 6. Placemark-Bereinigung

Die labelloc-Altspalten `country`, `administrative_area`, `sub_administrative_area`,
`locality`, `sub_locality`, `postal_code`, `name`, `thoroughfare` sind durch `country_iso`
und `admin_*` ersetzt und sollen weg. Das ist bereits als **Phase O3, Task 20** geplant
(zusammen mit `samples.mtb`, `fieldtrips.admin_units/mtb/country/admin_area` und den
iOS-Altspalten) und bleibt dort, weil vorher der Backfill (O3, Task 19) die Werte
manueller Alt-Placemarks nach `admin_*` übernehmen muss — sonst gehen sie verloren
(lokal gibt es einen manuellen Placemark mit Altwerten).

**Reihenfolge:** O2-Test → diese Phase (Zeit, ID, Höhe) → O3 (Backfill nach der neuen
Höhenregel aus §5, danach Altspalten löschen). Der O3-Backfill schreibt also keine
`elevation_dem` mehr.

## Entscheidungen nach Builder-Check (Claudes Calls, von Jo zu prüfen)

1. **Sammeltag kommt vom Client.** Die App berechnet `collecting_day` beim Anlegen
   (Gerätezeitzone + gecachter Rollover) und schickt ihn mit. Das Backend übernimmt ihn
   und ordnet danach die Exkursion zu; es rechnet nur selbst (Sample-`timezone` +
   `users.day_cutoff_hour`), wenn der Wert fehlt (Altclient). So bleibt „einmal beim
   Anlegen festgelegt“ auch bei späterer Rollover-Änderung oder zwei Geräten stabil.
2. **Bestehende Rollover-Werte bleiben unangetastet.** Lokal stehen alle 4 User bereits
   auf `day_cutoff_hour = 0` (das Backend ignorierte das Feld bisher und rechnete fest mit 5).
   Keine Datenmigration; Jo stellt 5:00 in den Einstellungen ein. Bereits angelegte
   Samples/Exkursionen behalten ihren Sammeltag.
3. **Unique-Index-Migration:** Bestandsduplikate pro `(owner, sample_id)` erhalten vor dem
   Anlegen des Index denselben Konfliktsuffix `(2)`, `(3)` (gleiche Ausnahmeregel; lokal
   gibt es aktuell keine Duplikate und keine leeren IDs).
4. **Konfliktsuffix auch beim Update.** Ändert ein synchronisiertes Update die ID auf eine
   beim User schon vergebene, hängt das Backend ebenfalls den Suffix an (kein Sync-Fehler);
   die App kennzeichnet das Sample wie beim Anlegen.
5. **Altbestand-Zeitzone gilt als `device`.** Bestandsrows bekommen `timezone_source =
   device` und dürfen von Ortus überschrieben werden. Eine eigene Nachanreicherung für
   alte Samples gibt es in dieser Phase nicht (das ist Sache des O3-Backfills).
6. **Exkursionen** rechnen mit der Zeitzone ihres ersten Samples (Fallback
   `Europe/Berlin` nur für Altdaten ohne `timezone`), nicht mehr fest mit `berlin`.
7. **Zähler leben nur in der App.** Weil das Backend keine IDs mehr vergibt, entfällt die
   serverseitige Sequenzvergabe (`nextSequence`, `ensureSequenceAtLeast`, Parsen von
   Tageszählern); `sample_sequences` wird nicht mehr beschrieben. Die App schlägt die
   nächste Nummer aus ihren lokalen Samples vor (Tagessequenz: höchste `<seq>` des
   Sammeltags im aktuellen Format + 1; laufende Nummer: lokal persistierter Höchststand,
   mindestens Offset) und überspringt dabei lokal schon vergebene IDs. Zwei offline
   Geräte können dieselbe Nummer vorschlagen — das fängt der Konfliktsuffix ab.

## Bestehender Code (Einstiegspunkte)

- Backend: `backend/internal/hooks/sample_create.go` (`processSample`, `codeConflicts`,
  `defaultCutoff`, `berlin`), `backend/internal/codes/codes.go`,
  `backend/internal/enrichment/`, `backend/internal/geoplace/map.go`,
  Migration `1700000017_phase_r3_samples_extended.go` (Ursprung `time_zone`).
- iOS: `Core/Geo/Codes/` (`Codes.swift`, `SampleCodeTemplate.swift`),
  `Core/Persistence/LocalSampleStore.swift`, `LocalSample.swift`, `Core/Models/Sample.swift`,
  `Core/Config/AppConfig.swift`, `Features/Settings/SettingsView.swift`,
  `Features/Home/HomeViewModel.swift`, `Features/SampleEditor/`, `Features/Samples/SampleDetailView.swift`,
  `Core/Geo/SampleLocationResolver.swift`, Package `FieldworksGeo` (`OrtusMapper`).

## Dem Builder überlassen

- Exakte Feld-/Spaltennamen für `timezone_source` und die User-Einstellungen
  (Präfix, Offset, Format), sofern konsistent mit bestehenden Konventionen.
- UI-Details des Zeitzonen-Pickers und der Einstellungen (Design-System- und
  A11y-Regeln gelten).
- Wie der Zähler der laufenden Nummer über Geräte hinweg initialisiert wird (z. B. aus
  Backend-Stand beim Login), solange offline Vorschläge möglich sind und doppelte
  Vergabe über den Konfliktsuffix abgefangen wird.
- Reihenfolge und Zuschnitt der Tasks; TDD wie bisher.
