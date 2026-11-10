# Probe nachtragen, Bearbeiten-Formular, Koordinatenformate — Design

Stand: 2026-11-10 · baut auf Phase E (`feat/sofort-anlage`) auf · Haupt-Checkout, keine Worktrees

## Warum

Nicht jede Probe entsteht im Feld. Jo bekommt Tiere von Kollegen oder pflegt alte eigene Daten ein.
Dafür gibt es heute nur den versteckten Modus „Nachträglich“ im Editor (Koordinate nur per Kartentipp,
nur WGS84). Altfunde liegen aber oft in landesüblichen Projektionen vor (Gauß-Krüger, ETRS89/UTM, MGRS),
oder die Information steckt in einem Foto.

Gleichzeitig ist der Sample-Editor überladen: Zeitfenster, Zeitzone und Ortsangaben lassen sich dort
direkt ändern. Der Editor ist aber das Feldbuch. Dort tippt man Notizen und macht Fotos, später kommen
Habitat-Aufnahmen (Simple Relevés mit Pflanzeneingabe und Fotobestimmung) dazu. Er soll ruhig bleiben
und kein Fachwissen verlangen. Alles Technische gehört in ein eigenes Bearbeiten-Formular.

## Begriffe

- **Sample-Ansicht** = der heutige `SampleEditorView` (Feldbuch). Bleibt der Ort für ID, Notizen,
  Fotos, Bestimmungen.
- **Bearbeiten-Formular** = neuer Screen, aus der Sample-Ansicht über „Bearbeiten“ erreichbar, in Gruppen.
- **Nachtrage-Dialog** = Dialog für „Probe nachtragen → Mit Koordinate“.

## Ziele

### 1. Zwei Wege zum Nachtragen

Der Home-Eintrag „Probe nachtragen“ (Phase E) öffnet eine Auswahl mit zwei Wegen: „Mit Koordinate“ und
„Aus Foto“. Der bisherige Modus „Nachträglich“ (Segment-Picker im ungespeicherten Anlegepfad) entfällt.

**a) Mit Koordinate.** Der Nachtrage-Dialog enthält:
- die Sample-ID, vorbelegt wie bei der Sofort-Anlage,
- das Koordinatensystem, vorbelegt mit dem globalen Anzeigeformat (Ziel 4),
- die Koordinatenfelder passend zum System (Ziel 3),
- den Button „Anlegen“ und „Abbrechen“.

„Anlegen“ fragt Ortus. Erst bei Erfolg entsteht das Sample mit der WGS84-Koordinate aus der Antwort,
den Ortsdaten und der Zeitzone, danach öffnet sich die Sample-Ansicht. Scheitert die Anfrage, bleibt der
Dialog offen, zeigt eine Fehlermeldung und lässt die Eingaben stehen. Der User korrigiert und sendet
erneut oder bricht ab (dann entsteht nichts). Als gescheitert gilt: Netzfehler oder Timeout, HTTP-Fehler,
eine Antwort ohne `wgs84` (Ortus liefert bei manchen unsinnigen Koordinaten HTTP 200 mit leerem Body).
Ohne Netz ist Anlegen daher nicht möglich (Entscheidung von Claude, siehe unten).
Zeit: Beginn = jetzt gerundet wie Phase Z, in der Zeitzone aus Ortus; der User korrigiert die Zeit
danach im Formular.

**b) Aus Foto.** Öffnet die Fotogalerie, genau **ein** Foto.
- Mit GPS in den Metadaten: dieselbe Ortus-Anfrage wie bei a). Erfolg → Sample anlegen, Sample-Ansicht.
  Fehler → der Nachtrage-Dialog öffnet sich mit der Foto-Koordinate (WGS84) vorbelegt und der Meldung.
- Aufnahmezeit aus den Metadaten wird Beginn (Ende nach Phase-Z-Regel). Liegt keine Zeitzonenangabe im
  Foto (`OffsetTimeOriginal`), wird die Aufnahmezeit in der Ortus-Zeitzone der Koordinate gelesen, ohne
  Koordinate in der Zeitzone des Geräts.
- Ohne GPS und/oder ohne Aufnahmezeit: es entsteht trotzdem sofort ein Sample, ohne Koordinate bzw. mit
  Beginn = jetzt, Zeitzone des Geräts. Fehlende Angaben füllt der User im Formular.
- Das Bild hängt in jedem Fall als Foto am Sample (normaler Foto-Pfad, wird gesynct).
- Manuelle Samples bekommen keine Hintergrund-Ortung (`PendingFixService` nicht registrieren).

Die ID-Regeln aus Phase E gelten auch hier (leer bei neuem Sample → Nachfrage beim Zurück, doppelt →
Hinweis).

### 2. Sample-Ansicht (Feldbuch)

- Ortsdaten als eine Gazetteer-Zeile, z.B. „Deutschland, Bayern, Unterfranken, Landkreis Würzburg“
  (Länder-spezifische Begriffe wie bisher über `AdminLabelTable`/`PlaceDisplay`).
- Darunter Peilung („14 km SE Würzburg“), Exposition und Hangneigung, sofern vorhanden.
- Koordinate im globalen Anzeigeformat, darunter der Name des Formats (wie in der alten App).
  Höhe und Genauigkeit wie bisher.
- Datum/Zeit nur noch Anzeige. Bei All Day ohne Uhrzeit.
- Ein „Bearbeiten“-Button öffnet das Bearbeiten-Formular.
- Was nicht mehr in der Sample-Ansicht steht: Zeitfenster-Picker, Zeitzonen-Picker,
  „Ortsangaben bearbeiten“, Kartenkorrektur. Alles wandert ins Formular.
- Bleibt: ID, Notizen, Fotos (Kamera), Bestimmungen, Fieldtrip, Sync-/Status-Hinweise.

### 3. Bearbeiten-Formular

Gruppen in dieser Reihenfolge:

1. **Koordinate**
   - Koordinatensystem (Eingabe), vorbelegt mit dem Anzeigeformat.
   - Koordinatenfelder je System, Beschriftung wie im Ortus-Frontend: WGS84 „Breitengrad“/„Längengrad“;
     UTM-Projektionen und Gauß-Krüger „Rechtswert“/„Hochwert“; Web Mercator „X“/„Y“; MGRS ein Feld.
     Geographische Schreibweisen (Dezimalgrad, Grad/Dezimalminuten, Grad/Minuten/Sekunden) werden lokal
     nach Dezimalgrad geparst.
   - Höhe, horizontale und vertikale Genauigkeit. Jede Höhenänderung setzt `elevation_source = manual`
     (Phase Z).
   - „Auf Karte zeigen“, sobald eine Koordinate eingetragen ist: öffnet die bestehende Karte
     (`CoordinatePickerView`, Tipp setzt Punkt, „Übernehmen“ schreibt zurück ins Formular).
   - „Ortsdaten neu abfragen“: neue Ortus-Anfrage für die eingetragene Koordinate (rechnet bei
     Nicht-WGS84 um, aktualisiert Ortsdaten, Zeitzone, Höhe nach den bestehenden Regeln der
     Koordinatenkorrektur). Fehler werden in der Gruppe angezeigt, die Eingabe bleibt stehen.
   - Gespeichert wird **immer nur WGS84 dezimal**. Eine Eingabe in einem anderen System wird beim
     Übernehmen in WGS84 umgerechnet (lokal für Geographisch/UTM/MGRS, sonst über Ortus). Das Formular
     speichert nicht, solange eine Nicht-WGS84-Eingabe nicht umgerechnet werden konnte.
   - Eine geänderte Koordinate läuft durch den bestehenden Korrekturpfad (Ortus/Höhe/Zeitzone folgen,
     Rückfragen zu manuellen Ortsangaben wie heute).
2. **Zeit** — Reihenfolge: Beginn, Ende, Zeitzone, All Day. All Day an → Uhrzeiten entfallen (nur
   Datum). Zeitzonen-Picker wie bisher (Region → Zone). Speicherung in UTC wie Phase Z.
3. **Ortsdaten (Gazetteer)** — die heutigen Felder aus `PlaceEditorView` (manuelle Ortsangaben).

Weitere Gruppen (Sammler, Habitat) folgen in späteren Phasen.

Speichern: Das Formular hat „Fertig“/„Abbrechen“ (oder Zurück speichert, wie die Sample-Ansicht — dem
Builder überlassen, aber konsistent mit Phase E: keine verlorenen Eingaben).

### 4. Koordinatenformate

- **Anzeigeformat**: globale Einstellung in „Einstellungen“. Auswahl wie die alte App:
  Geographisch in 8 Schreibweisen (Dezimalgrad, Dezimalgrad mit °, Grad/Dezimalminuten,
  Grad/Minuten/Sekunden, jeweils mit Vorzeichen oder mit N/S/E/W), UTM, MGRS. Default: Dezimalgrad mit Vorzeichen (wie alte App).
  Die Anzeige wird lokal berechnet, funktioniert offline.
- **Nur-Eingabe-Systeme**: alles, was Ortus umrechnet und im Ortus-Frontend steht — WGS 84 (EPSG:4326),
  Web Mercator (EPSG:3857), ETRS89 / UTM 32N (EPSG:25832), ETRS89 / UTM 33N (EPSG:25833),
  DHDN / Gauß-Krüger Zone 2 (EPSG:31466), DHDN / Gauß-Krüger Zone 3 (EPSG:31467), MGRS.
  Weitere Landesprojektionen (CH, BE, GB …) sollen sich später durch einen Listeneintrag ergänzen lassen.
  Diese Systeme werden nie angezeigt, nur eingegeben.
- **Umrechnung lokal**: die alten freien GEOTRANS-C-Quellen aus `../fieldworksdiary/fieldworksdiary/`
  (`mgrs`, `utm`, `ups`, `tranmerc`, `polarst`; „LICENSES: None apply to this component“) werden als
  C-Target ins Swift-Paket `FieldworksGeo` übernommen, mit dünnem Swift-Wrapper und Tests gegen
  Referenzwerte (u.a. die Ortus-Antworten unten). Keine Objective-C-Brücke.

### 5. Ortus-Anfrage mit Koordinatensystem

`GET /api/v1/query`:
- WGS84: `srid=4326&lon=…&lat=…`
- andere EPSG: `srid=<code>&x=<Rechtswert/X>&y=<Hochwert/Y>`
- MGRS: `mgrs=<string>` (überschreibt die anderen Parameter)
- Erfolg: `wgs84: {lat, lon}` ist die zu speichernde Koordinate; Fehler: `{"error", "message"}` mit 4xx/5xx.

Geprüft am 2026-11-10 gegen `https://ortus.fieldworksdiary.org` (Kleinochsenfurt):
`srid=25832&x=574400&y=5503700` → 49.681230, 10.031340 · `mgrs=32UNA7440003700` → dasselbe ·
`srid=31467&x=3574500&y=5505500` → 49.681563, 10.031282 · `srid=25832&x=99999999&y=1` → HTTP 200,
leerer Body · `mgrs=32UXX1` → 400 mit Meldung.

Die Produktiv-Instanz rechnet derzeit nur WGS84 korrekt. Für Entwicklung und Test der SRID-Pfade wird der
Ortus-Endpoint der App (Einstellungen, `AppConfig.ortusEndpointURL`) auf `https://ortus.fieldworksdiary.org`
gestellt. Kein fest verdrahteter Endpoint im Code.

## Nicht-Ziele

- Mehrere Fotos auf einmal / Massenimport.
- Anzeige in Projektionen außer Geographisch/UTM/MGRS.
- Sammler-Gruppe, Habitat/Relevés, Wetterdaten.
- Account-Umbau (Owner per `ownerId` statt E-Mail, durchgehende Zugriffsregeln, Login-Wechsel ohne
  Zugangsverlust) — eigenes Projekt, wird in `PHASES.md` notiert.
- Backend-Änderungen außer der einen unten (Ortus wird vom Client gefragt; das Backend reichert wie
  bisher mit WGS84 an). Ausnahme, folgt aus der Sammeltag-Entscheidung: ein Feld für „nachgetragen“
  (Migration) und im Update-Hook die Neuzuordnung zum Fieldtrip, wenn sich `collecting_day` eines
  nachgetragenen Samples ändert. Sonst landet ein Altfund im Fieldtrip des Erfassungstags.

## Entscheidungen von Claude (zur Prüfung durch Jo)

- Nachtragen mit Koordinate braucht Netz; ohne Netz Fehlermeldung im Dialog. Grund: Nachtragen passiert
  meist am Schreibtisch, und eine falsch oder gar nicht umgerechnete Koordinate ist schlimmer als keine.
- Foto mit GPS, aber gescheiterter Ortus-Anfrage → Nachtrage-Dialog vorbelegt, statt Sample ohne Ortsdaten.
- Aufnahmezeit ohne Zeitzone im Foto wird in der Ortus-Zeitzone der Koordinate gelesen.
- GEOTRANS als C-Target in `FieldworksGeo` statt Objective-C-Brücke.
- Gauß-Krüger und andere Landesprojektionen nur als Eingabe (mit Jo abgestimmt).

- Umrechnung: Geographisch, UTM (WGS84) und MGRS lokal mit GEOTRANS; alle Nur-Eingabe-Systeme
  einschließlich ETRS89/UTM 32N/33N gehen mit `srid` an Ortus (ein Pfad für alle Projektionen, kein
  Sub-Meter-Unterschied zwischen ETRS89 und WGS84 zu diskutieren).
- Bearbeiten-Formular: Zurück speichert wie die Sample-Ansicht (Phase E), kein „Fertig“-Button. Eine
  nicht umrechenbare Eingabe blockiert nur die Koordinate: die Gruppe zeigt den Fehler, die gespeicherte
  Koordinate bleibt unverändert, Zeit und Ortsdaten werden trotzdem gespeichert. Beim Zurück mit
  unübernommener Koordinate-Eingabe fragt das Formular einmal nach („Koordinate verwerfen?“).
- Foto: `PHPickerViewController`/`PhotosPicker` ohne Fotomediathek-Berechtigung; das Original wird als
  Datei geladen, damit GPS und Aufnahmezeit erhalten bleiben. Hat der User beim Auswählen den Ort
  entfernt, gilt das Foto als ohne GPS. Die Foto-Position gilt als Fundort, auch bei alten Fotos.
- Keine Datenmigration: bestehende, im Modus „Nachträglich“ angelegte Samples sind normale Samples.
- Sammeltag nachgetragener Samples (Wege a und b): folgt dem Beginn, wenn der User ihn im Formular
  ändert (Ausnahme zur Phase-Z-Regel, die für Feldproben bleibt). Die Sample-ID bleibt trotzdem
  unangetastet. Beim Weg „Aus Foto“ richtet sich der ID-Vorschlag nach der Aufnahmezeit. Dafür bekommt
  das Sample eine Kennzeichnung als nachgetragen (Feld/Name dem Builder überlassen, muss synchronisiert
  werden). Von Jo mit „starten“ freigegeben.
- Ortus-Produktiv wird für SRID-Anfragen in Ortus selbst repariert; die App behandelt das nicht
  gesondert (Endpoint bleibt eine Einstellung).

## Bestehender Code (Einstiegspunkte)

`Features/Home/HomeView.swift` („Probe nachtragen“), `Features/SampleEditor/SampleEditorView.swift` /
`SampleEditorViewModel.swift` (Modus `.later`, `timeWindowEditor`, `locationTimeSection`,
`placeSection`, Korrekturpfad `resolveAfterCorrection`), `Features/Samples/SampleDetailView.swift`
(nur noch von dort ins Editor-Create verlinkt), `Features/AddSample/CoordinatePickerView.swift`,
`Features/AddSample/PhotoPicker.swift` (heute Kamera, Galerie nur im Simulator; EXIF wird nirgends
gelesen), `Core/Photos/PhotoStorage.swift`, `Core/Persistence/LocalPhotoStore.swift`,
`Core/Geo/SampleLocationResolver.swift`, `Core/Geo/PlaceDisplay.swift`, Ortus-Client und
`OrtusMapper` in `FieldworksGeo`, `Features/SampleEditor/TimeZonePickerView.swift`,
`PlaceEditorView`/`PlaceEditorViewModel`, `Core/Config/AppConfig.swift`,
`Features/Settings/SettingsView.swift`. Alte App: `../fieldworksdiary/fieldworksdiary/`
(`GTWConversionManager`, `Conversion.m` für Formatbeispiele, `CoordinateSystem.m`).
