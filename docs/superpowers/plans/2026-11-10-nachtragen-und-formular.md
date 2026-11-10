# Probe nachtragen, Bearbeiten-Formular, Koordinatenformate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Zwei Nachtrage-Wege (Koordinate in beliebigem Ortus-System, Foto mit EXIF), ein gruppiertes Bearbeiten-Formular und eine ruhigere Sample-Ansicht mit Koordinate im global gewählten Anzeigeformat.

**Architecture:** Lokale Umrechnung/Formatierung über die alten GEOTRANS-C-Quellen als C-Target in `FieldworksGeo`; Nur-Eingabe-Projektionen über Ortus (`srid`/`mgrs`), gespeichert wird immer WGS84. Nachgetragene Samples tragen ein Kennzeichen; ihr Sammeltag folgt dem Beginn, das Backend ordnet den Fieldtrip dann neu zu.

**Tech Stack:** SwiftUI, GRDB, PhotosUI, ImageIO, SPM (C-Target), Go + PocketBase v0.22.

**Spec:** `docs/superpowers/specs/2026-11-10-nachtragen-und-formular-design.md`

## Global Constraints

- Phase heißt in `PHASES.md` „Phase N – Probe nachtragen, Bearbeiten-Formular, Koordinatenformate“.
- Branch `feat/nachtragen` (zweigt von `feat/sofort-anlage` ab) im Haupt-Checkout `/Users/jbrunner/work/projects/fieldworksdiary-ng`. **Keine git worktrees.**
- Conventional Commits; jede Message endet mit Leerzeile + `Claude-Session: https://claude.ai/code/session_015iSEsSrMrE4BRew7xJkVcS`. Nicht pushen. Dateien explizit stagen; nie das Umformatierungsrauschen in `ios/Fieldworksdiary/Resources/Localizable.xcstrings` oder `ios/FieldworksdiaryTests/PendingMutationsStoreTests.swift` (Jos lokale Änderung) mitnehmen, außer eigene String-Ergänzungen.
- Gespeichert wird nur WGS84 dezimal (6 Nachkommastellen); Nur-Eingabe-Systeme werden nie angezeigt.
- Ortus-Endpoint kommt aus `AppConfig.ortusEndpointURL`, nichts fest verdrahten. Für SRID-Tests: `https://ortus.fieldworksdiary.org` (Prod rechnet derzeit nur WGS84 korrekt).
- UI-Texte exakt: Auswahl „Mit Koordinate“ · „Aus Foto“; Dialog-Titel „Probe nachtragen“, Buttons „Anlegen“ · „Abbrechen“; Feld „Koordinatensystem“; Formular-Button in der Sample-Ansicht „Bearbeiten“; Gruppen „Koordinate“ · „Zeit“ · „Ortsdaten“; „Auf Karte zeigen“ · „Ortsdaten neu abfragen“; Zeit-Felder „Beginn“ · „Ende“ · „Zeitzone“ · „Ganztägig“; Rückfrage „Koordinate verwerfen?“ mit „Verwerfen“ (destructive) · „Weiter bearbeiten“; Fehler offline „Keine Verbindung zu Ortus. Bitte später erneut versuchen.“; Fehler Ortus „Ortus konnte die Koordinate nicht umrechnen: <message>“ (ohne message: „Ortus konnte die Koordinate nicht umrechnen.“); Einstellung „Koordinatenformat“.
- Eingabesysteme (Reihenfolge, Labels exakt): „WGS 84 (EPSG:4326) - GPS“, „Web Mercator (EPSG:3857)“, „ETRS89 / UTM Zone 32N (EPSG:25832)“, „ETRS89 / UTM Zone 33N (EPSG:25833)“, „DHDN / Gauß-Krüger Zone 2 (EPSG:31466)“, „DHDN / Gauß-Krüger Zone 3 (EPSG:31467)“, „MGRS (Military Grid Reference System)“. Feldlabels: 4326 „Breitengrad“/„Längengrad“; 25832/25833/31466/31467 „Rechtswert“/„Hochwert“; 3857 „X“/„Y“; MGRS ein Feld, Platzhalter `32U NA 01234 56789`. Komma als Dezimaltrenner akzeptieren.
- Anzeigeformate (Einstellung, Default Dezimalgrad mit Vorzeichen): Geographisch 8 Schreibweisen (Dezimalgrad / Dezimalgrad mit ° / Grad+Dezimalminuten / Grad+Minuten+Sekunden, je mit Vorzeichen oder N/S/E/W), UTM, MGRS. Formatbeispiele und Präzision wie `../fieldworksdiary/fieldworksdiary/Conversion.m` (Dezimal `%.6f`, DM `%02u°%02.2f'`, DMS `%u°%u'%01.1f"`, MGRS 5-stellig mit Leerzeichen `32U NA 12345 67890`, UTM `32U 574400 5503700`).
- iOS-Regeln: `.claude/rules/DESIGN-SYSTEM.md`, `ACCESSIBILITY-IOS.md`, `LOGGING.md` (keine Koordinaten loggen). Keine Force-Unwraps.
- Typecheck: `cd ios && xcodegen generate && xcodebuild build-for-testing -project Fieldworksdiary.xcodeproj -scheme Fieldworksdiary -destination 'generic/platform=iOS Simulator' -IDEBuildingContinueBuildingAfterErrors=YES CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error:' | grep -v 'objc_abi_version\|Linker command failed'` → leer. Paket: `cd ios/Packages/FieldworksGeo && swift test`. Backend: `cd backend && go test ./...`. App-Tests führt der Controller über Xcode aus.

## Referenzwerte (Ortus Test-Instanz, 2026-11-10, Kleinochsenfurt)

- `srid=25832&x=574400&y=5503700` → lat 49.681230, lon 10.031340
- `mgrs=32UNA7440003700` → lat 49.681230, lon 10.031340 (Ortus-SRID 32632)
- `srid=31467&x=3574500&y=5505500` → lat 49.681563, lon 10.031282
- `srid=25832&x=99999999&y=1` → HTTP 200, leerer Body (= Fehler)
- `mgrs=32UXX1` → HTTP 400 `{"error":"Bad Request","message":"mgrs: invalid input: …"}`

## Review Focus

1. Ortus antwortet 200 ohne `wgs84` oder mit leerem Body → Dialog zeigt Fehler, kein Sample, Eingaben bleiben stehen.
2. Foto mit Ort entfernt / ohne EXIF / HEIC → Sample entsteht trotzdem, Foto hängt dran, keine Hintergrund-Ortung.
3. Altfund: Beginn im Formular auf 2019 geändert → Sammeltag folgt, Fieldtrip wird nach Sync neu zugeordnet, ID bleibt; ein Feldsample mit geändertem Beginn behält seinen Sammeltag.
4. Ganztägig an/aus → Uhrzeiten verschwinden/erscheinen, gespeicherter Beginn bleibt im richtigen lokalen Kalendertag (Zeitzone beachten, auch Atlantic/Canary).
5. Formular verlassen mit nicht umgerechneter Koordinaten-Eingabe → Rückfrage; Zeit- und Ortsänderungen gehen nicht verloren.

---

### Task 0: Phasenstatus (Controller)
- [ ] `PHASES.md`: Abschnitt „Phase N – …“ in progress mit Spec/Plan-Links, Tasks 1–7; zusätzlich Eintrag „Projekt Account-Umbau (pending)“: Owner per `ownerId` statt E-Mail, durchgehende Zugriffsregeln (nur eigene Einträge), Login-Wechsel Apple/Google/Passwort ohne Zugangsverlust, Sammler-Default am Account. Commit `docs(phases): Phase N eingetragen`.

### Task 1: GEOTRANS in FieldworksGeo — Formatieren und Parsen
**Files:** Create `ios/Packages/FieldworksGeo/Sources/CGeotrans/` (C-Quellen + `include/` mit Headern aus `../fieldworksdiary/fieldworksdiary/{mgrs,utm,ups,tranmerc,polarst}`, Lizenzkommentare unverändert), `Sources/FieldworksGeo/CoordinateFormat.swift`, `Sources/FieldworksGeo/CoordinateConverter.swift`, Tests `Tests/FieldworksGeoTests/CoordinateConverterTests.swift`; Modify `Package.swift` (Target `CGeotrans`, `FieldworksGeo` hängt davon ab).
**Produces:**
- `public enum CoordinateDisplayFormat: String, CaseIterable, Codable { case decimalSign, decimalDirection, degreesSign, degreesDirection, degreesMinutesSign, degreesMinutesDirection, dmsSign, dmsDirection, utm, mgrs }` mit `public var title: String` (deutscher Name für Einstellung/Beschriftung) und `static let default = .decimalSign`.
- `public enum CoordinateConverter { static func format(lat: Double, lon: Double, as: CoordinateDisplayFormat) -> String?; static func parseGeographic(_ text: String) -> (lat: Double, lon: Double)?; static func parseGeographicComponent(_ text: String, isLatitude: Bool) -> Double?; static func fromUTM(zone: Int, northernHemisphere: Bool, easting: Double, northing: Double) -> (lat: Double, lon: Double)?; static func fromMGRS(_ text: String) -> (lat: Double, lon: Double)?; static func toMGRS(lat:lon:precision:) -> String? }` (nil bei Fehler, kein Crash).
- [ ] Tests: `format(49.681230, 10.031340, .mgrs)` beginnt mit `32U NA 744` und `fromMGRS("32UNA7440003700")` ≈ (49.681230, 10.031340) ±1e-5; `fromUTM(32, true, 574400, 5503700)` ≈ dieselben Werte; Dezimal/DM/DMS je Vorzeichen- und Richtungsvariante für eine Nord-Ost- und eine Süd-West-Koordinate (Ergebnisstrings im Test festlegen, Format wie `Conversion.m`); `parseGeographic` akzeptiert `49,681230 10,031340`, `N49°40.874' E10°01.880'`, `49°40'52.4"N 10°1'52.8"E` und lehnt `abc` / lat > 90 ab; `parseGeographicComponent("49°40'52.4\"N", isLatitude: true)` ≈ 49.681222, `("W10,5", isLatitude: false)` = -10.5; MGRS-Müll → nil.
- [ ] `swift test` grün. Commit `feat(geo): GEOTRANS für Koordinatenformate und Umrechnung`.

### Task 2: Ortus-Anfrage mit Koordinatensystem
**Files:** Modify `ios/Fieldworksdiary/Core/Ortus/OrtusClient.swift`, `ios/Packages/FieldworksGeo/Sources/FieldworksGeo/OrtusResponse.swift` (`wgs84: {lat, lon}?` decodieren); Create `Sources/FieldworksGeo/InputCoordinateSystem.swift`; Tests (App-Tests für Request-Bau mit `URLProtocol`-Stub, Paket-Test für Decoding).
**Produces:**
- `public enum InputCoordinateSystem: String, CaseIterable, Identifiable { case wgs84 = "4326", webMercator = "3857", etrs89utm32 = "25832", etrs89utm33 = "25833", gk2 = "31466", gk3 = "31467", mgrs }` mit `title`, `firstLabel`, `secondLabel` (nil bei MGRS), `placeholder`, Reihenfolge und Texte aus Global Constraints. Neue Projektionen = ein weiterer case.
- `public struct CoordinateInput: Equatable { var system: InputCoordinateSystem; var first: String; var second: String }` (MGRS nutzt `first`) mit `func queryItems() throws -> [URLQueryItem]` (4326 → `srid,lon,lat`, jedes Feld akzeptiert Dezimal, DM oder DMS über `CoordinateConverter.parseGeographicComponent`; EPSG → `srid,x,y`; MGRS → `mgrs`; Komma→Punkt; leere/nicht-numerische Eingabe → `CoordinateInputError.invalidNumber`).
- `OrtusQuerying.query(input: CoordinateInput) async throws -> OrtusResponse` (bestehendes `query(lat:lon:)` bleibt und ruft intern `.wgs84` auf).
- `enum OrtusQueryError: Error { case offline, server(message: String?), noWGS84 }` mit `var userMessage: String` (Texte aus Global Constraints). Leerer Body / fehlendes `wgs84` → `.noWGS84`; `URLError` Netz/Timeout → `.offline`; 4xx/5xx → `.server(message:)` aus `{"message"}`.
- [ ] Tests: Query-Items für alle drei Formen inkl. Komma; 200 mit leerem Body → `.noWGS84`; 400-Body aus den Referenzwerten → `.server` mit message; `URLError(.notConnectedToInternet)` → `.offline`; Decoding einer Antwort mit `wgs84`.
- [ ] Commit `feat(ios): Ortus-Anfrage mit Koordinatensystem`.

### Task 3: Backend — nachgetragene Samples, Fieldtrip-Neuzuordnung
**Files:** Create `backend/migrations/1700000028_phase_n_retrospective.go` (Bool-Feld `is_retrospective` auf `samples`, Default false; Down entfernt es); Modify `backend/internal/hooks/sample_create.go` (Update-Hook), Tests im bestehenden Hook-Testmuster.
**Produces:** Beim Update eines Samples mit `is_retrospective = true`, dessen `collecting_day` sich ändert: Fieldtrip über `grouping.FindOrCreate` für den neuen Tag neu zuordnen (in Transaktion), `sample_id` bleibt unangetastet (außer dem bestehenden Kollisions-Suffix). Für `is_retrospective = false` bleibt `collecting_day` wie bisher fix (Client-Wert wird ignoriert bzw. bisheriger Wert bleibt — bestehendes Verhalten im Code nachsehen und beibehalten).
- [ ] Tests: retrospektives Sample, `collecting_day` 2026-11-10 → 2019-05-04 → neuer Fieldtrip mit Tag 2019-05-04, `sample_id` unverändert; nicht-retrospektives Sample mit geändertem `collecting_day` → Fieldtrip und Tag unverändert; leerer alter Fieldtrip wird nicht gelöscht (kein Datenverlust; Aufräumen ist nicht Teil).
- [ ] `go test ./...` grün. Commit `feat(backend): Fieldtrip folgt dem Sammeltag nachgetragener Samples`.

### Task 4: iOS-Modell, Sammeltag-Regel, Einstellung Koordinatenformat
**Files:** Modify `Core/Persistence/LocalSample.swift` (`isRetrospective`), GRDB-Migration v18 (`is_retrospective` Bool Default false), `LocalSampleStore.swift`, `Core/Sync/SyncRunner.swift` + `SampleClient.swift` (Feld pushen/hydrieren), `Core/Config/AppConfig.swift` (`coordinateDisplayFormat: CoordinateDisplayFormat`, UserDefaults, Default `.decimalSign`), `Features/Settings/SettingsView.swift` (Picker „Koordinatenformat“, Beispiel der aktuellen Auswahl darunter), Tests.
**Produces:**
- `LocalSampleStore.createRetrospective(code: String, latitude: Double?, longitude: Double?, beginDate: Date, timezone: String, timezoneSource: TimezoneSource) throws -> LocalSample` — legt mit `isRetrospective = true`, `locationSource` = manuell (bestehenden Wert nachsehen), Zeitfenster nach Phase-Z-Regel (`SampleTime`), Sammeltag aus Beginn + Rollover-Einstellung in der übergebenen Zeitzone an, queued Create, **kein** `PendingFixService.register`.
- Beim Ändern von Beginn/Zeitzone/Ganztägig (bestehende Setter-Pfade im Store): für `isRetrospective` Sammeltag neu berechnen, für Feldsamples nicht.
- [ ] Tests: `createRetrospective` mit Beginn 2019-05-04 10:00 Europe/Berlin → `collectingDay == "2019-05-04"`, Create-Mutation enthält `is_retrospective: true`; Beginn eines retrospektiven Samples auf 2019-05-05 ändern → Sammeltag folgt, Update-Mutation enthält `collecting_day`; Feldsample Beginn ändern → Sammeltag bleibt; Hydrierung übernimmt `is_retrospective`; AppConfig-Default `.decimalSign` und Persistenz.
- [ ] Commit `feat(ios): nachgetragene Samples und Koordinatenformat-Einstellung`.

### Task 5: Nachtragen — Auswahl, Dialog „Mit Koordinate“, „Aus Foto“
**Files:** Create `Features/Retrospective/RetrospectiveEntryView.swift` (Auswahl), `RetrospectiveCoordinateDialog.swift` + `RetrospectiveCoordinateViewModel.swift`, `PhotoMetadataReader.swift` (ImageIO), `RetrospectivePhotoImporter.swift`; Modify `Features/Home/HomeView.swift` („Probe nachtragen“ → Auswahl), `SampleEditorView`/`SampleEditorViewModel` (Modus `.later`, Segment-Picker und `initialMode` entfernen; `SampleEditorView(sampleID: nil)`-Pfad und `SampleDetailView.swift:71` bereinigen), `SampleLocationResolver` (Ergebnis einer bereits vorliegenden `OrtusResponse` anwenden, statt neu zu fragen), Tests.
**Consumes:** Task 2 `CoordinateInput`, `query(input:)`, `OrtusQueryError`; Task 4 `createRetrospective`.
**Produces:**
- `RetrospectiveCoordinateViewModel.submit() async -> String?` (neue Sample-ID oder nil; bei Fehler `errorMessage` gesetzt, Eingaben bleiben). Vorbelegung: Sample-ID wie Sofort-Anlage, System aus `AppConfig.coordinateDisplayFormat`: Anzeige `.mgrs` → `.mgrs`, alle anderen → `.wgs84`. Erfolg: `createRetrospective` mit `wgs84` aus der Antwort, Ortus-Zeitzone, Beginn = jetzt (Phase-Z-Rundung), dann Ortus-Ergebnis anwenden (Ortsdaten, Höhe, Zeitzone) ohne zweite Anfrage, Sync anstoßen, Sample-Ansicht pushen (`SampleEditorView(sampleID:, isNew: true)`).
- `struct PhotoMetadata { var coordinate: (lat: Double, lon: Double)?; var capturedAt: Date?; var hadExplicitOffset: Bool }` und `PhotoMetadataReader.read(_ data: Data, fallbackZone: TimeZone) -> PhotoMetadata` (GPS-Ref N/S/E/W beachten; `DateTimeOriginal` + `OffsetTimeOriginal`, ohne Offset in `fallbackZone` gelesen).
- Foto-Weg: `PhotosPicker` (genau ein Bild, keine Mediathek-Berechtigung), Originaldaten laden (`loadTransferable(type: Data.self)`). Mit GPS → Ortus `.wgs84`-Anfrage; Erfolg → Sample mit Aufnahmezeit (ohne Offset in Ortus-Zeitzone neu interpretieren), ID-Vorschlag nach Aufnahmetag; Fehler → Dialog mit Foto-Koordinate vorbelegt + Fehlermeldung, Foto bleibt für das spätere Sample vorgemerkt. Ohne GPS/Zeit → sofort Sample (Beginn = Aufnahmezeit oder jetzt, Zeitzone Gerät). Foto in jedem Fall über den bestehenden Foto-Pfad (`PhotoStorage.write`, `LocalPhotoStore.insert`) anhängen.
- [ ] Tests: Dialog-VM mit Stub-Ortus: Erfolg → Sample mit gerundeter WGS84-Koordinate, `isRetrospective`, Ortsdaten gesetzt, nur **eine** Ortus-Anfrage; `.noWGS84`/`.offline`/`.server` → kein Sample, `errorMessage` exakt laut Global Constraints, Eingaben unverändert; `PhotoMetadataReader` mit Testbildern (JPEG mit GPS Süd/West + Offset, JPEG ohne EXIF, HEIC falls im Simulator erzeugbar — sonst JPEG) als Test-Ressourcen; Foto ohne GPS → Sample ohne Koordinate mit Foto, keine `PendingFixService`-Registrierung.
- [ ] Commit `feat(ios): Probe nachtragen mit Koordinate oder aus Foto`.

### Task 6: Bearbeiten-Formular
**Files:** Create `Features/SampleForm/SampleFormView.swift`, `SampleFormViewModel.swift`, `CoordinateGroupView.swift`, `TimeGroupView.swift`; Gazetteer-Gruppe aus `PlaceEditorView`/`PlaceEditorViewModel` übernehmen (verschieben/einbetten, nicht duplizieren); Tests.
**Consumes:** Task 1 (Vorbelegung der Felder mit der gespeicherten Koordinate im Eingabesystem `.wgs84`; Umrechnung jeder Eingabe läuft über Ortus, siehe Ruling im Spec: lokal nur Anzeige und das Parsen geographischer Schreibweisen), Task 2 (`query(input:)`), Task 4 (Setter mit Sammeltag-Regel), bestehender Korrekturpfad (`resolveAfterCorrection`/Korrektur-Dialoge aus `SampleEditorViewModel` in das Formular-VM verlagern), `CoordinatePickerView`, `TimeZonePickerView`.
**Produces:** `SampleFormView(sampleID: String)`.
- Gruppe „Koordinate“: Picker „Koordinatensystem“ (`InputCoordinateSystem`), Felder je System, Höhe, horizontale/vertikale Genauigkeit (Höhe geändert → `elevation_source = manual`), „Auf Karte zeigen“ (nur mit Koordinate; Rückgabe füllt die Felder in WGS84), „Ortsdaten neu abfragen“ (Ortus mit Eingabe; Erfolg → WGS84 übernehmen + Ortsdaten/Zeitzone/Höhe nach Korrekturregeln; Fehler inline, Eingabe bleibt).
- Gruppe „Zeit“: „Beginn“, „Ende“, „Zeitzone“, „Ganztägig“ (an → nur Datums-Picker, gespeichert Beginn = 00:00 lokal, Ende = nil; aus → Phase-Z-Fenster ab 00:00 bzw. bisherigem Beginn).
- Gruppe „Ortsdaten“.
- Zurück speichert (eigener Back-Button + `interactivePopDisabled()` wie Phase E; Hintergrund speichert). Unübernommene Koordinaten-Eingabe beim Zurück → „Koordinate verwerfen?“; Zeit/Ortsdaten werden in jedem Fall gespeichert.
- [ ] Tests: Ganztägig an → `isAllDay`, Beginn 00:00 in Atlantic/Canary, Ende nil; Gauß-Krüger-Eingabe + Stub-Ortus → gespeicherte Koordinate = `wgs84` der Antwort (6 Nachkommastellen); Ortus-Fehler → Koordinate unverändert, Fehlertext, Zeitänderung trotzdem gespeichert; Höhe geändert → `elevationSource == .manual`; Zurück mit unübernommener Eingabe → Rückfragezustand.
- [ ] Commit `feat(ios): Bearbeiten-Formular mit Gruppen Koordinate, Zeit, Ortsdaten`.

### Task 7: Sample-Ansicht entschlacken
**Files:** Modify `Features/SampleEditor/SampleEditorView.swift`, `SampleEditorViewModel.swift`, `Core/Geo/PlaceDisplay.swift` (Gazetteer-Zeile), ggf. `Features/Samples/SampleDetailView.swift`; Tests (VM/Formatter) + Snapshot der Ortszeile falls Snapshot-Muster vorhanden.
**Consumes:** Task 1 `CoordinateConverter.format`, Task 4 `AppConfig.coordinateDisplayFormat`, Task 6 `SampleFormView`.
- Gazetteer-Zeile: Land + Verwaltungsebenen mit Komma, z.B. „Deutschland, Bayern, Unterfranken, Landkreis Würzburg“ (`PlaceDisplay.gazetteerLine(_ place:) -> String?`, Begriffe über `AdminLabelTable`). Darunter Peilung (`bearingLabel`), Exposition (`aspectCompass`/`aspectDeg`), Hangneigung (`slopeDeg`), nur vorhandene.
- Koordinate im Anzeigeformat, darunter `CoordinateDisplayFormat.title`; Höhe/Genauigkeit wie bisher.
- Datum/Zeit nur Anzeige (bei Ganztägig ohne Uhrzeit); Zeitfenster- und Zeitzonen-Picker, „Ortsangaben bearbeiten“ und Kartenkorrektur entfernen; Toolbar-Button „Bearbeiten“ pusht `SampleFormView`.
- [ ] Tests: `gazetteerLine` für DE-Fixture = „Deutschland, Bayern, Unterfranken, Landkreis Würzburg“ (Fixture/Begriffe aus bestehenden `OrtusMapperTests`-Daten ableiten, exakten String im Test festhalten); fehlende Ebenen werden übersprungen; Koordinatenzeile folgt der Einstellung (MGRS-Beispiel).
- [ ] Commit `feat(ios): Sample-Ansicht zeigt Ortsdaten kompakt, Bearbeiten über Formular`.

### Task 8: Phase N abschließen (Controller)
- [ ] Xcode-Suite grün, `swift test` und `go test ./...` grün, Typecheck leer; PHASES.md „implementiert, wartet auf Test durch Jo“ mit Testhinweisen (Ortus-Endpoint auf Test-Instanz stellen für Gauß-Krüger/MGRS).
