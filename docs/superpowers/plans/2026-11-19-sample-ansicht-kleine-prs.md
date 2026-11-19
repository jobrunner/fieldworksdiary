# Sample-Ansicht, kleine PRs (1, 2, 3, 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vier unabhängige Verbesserungen an `SampleEditorView`, jede als eigener PR: Koordinate/Höhe per Tap kopieren, Stift-Icon statt „…“, lesbare Datumszeile, kleinere Sample-Nummer.

**Architecture:** Reine SwiftUI-Änderungen in `ios/Legulus/Features/SampleEditor/`. Die Text-Erzeugung für die Zwischenablage ist eine pure Funktion im Paket `LegulusGeo`, die Datumsteile eine statische Funktion am ViewModel; beides mit Unit-Tests. Kein Backend, keine Persistenz.

**Tech Stack:** Swift, SwiftUI, XCTest, Paket `ios/Packages/LegulusGeo`.

**Spec:** `docs/superpowers/specs/2026-11-18-sample-ansicht-design.md` (Features 1, 2, 3, 5). Die PRs 4 und 6 (Fotos) bekommen einen eigenen Plan.

## Global Constraints

- Jeder PR hat einen eigenen Branch von `origin/main`: `feat/sample-copy-coordinate`, `feat/sample-toolbar-edit-icon`, `feat/sample-date-row`, `feat/sample-code-font`.
- Commits: Conventional Commits, Scope `ios`, Subject ohne Punkt, Imperativ. Commit-Footer: `Claude-Session: https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`. PR-Text endet mit `https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`.
- Englische Bezeichner, deutsche UI-Strings. Texte in Commits, PRs und Doku: kein Gendern, keine echten Dienst-Adressen.
- Nur Tokens (`AppSpacing`, `AppFont`, `AppRadius`, `AppMotion`, `AppColor`) und Atoms; keine Magic-Numbers, keine festen Font-Größen. In den angefassten View-Teilen vorhandene Magic-Numbers im selben Commit durch Tokens ersetzen, nicht darüber hinaus refactoren.
- A11y: Tap-Target ≥ 44 × 44 pt, Dynamic Type bis AX5 ohne Clipping, echte `Button`s, Icon-only-Buttons mit `accessibilityLabel`, Animationen über `AppMotion.respecting(_:reduceMotion:)`.
- Kein `print()`, keine Force-Unwraps.
- Vor jedem PR: `bash scripts/check-ios.sh` grün; Anti-Pattern-Greps aus `.claude/rules/ACCESSIBILITY-IOS.md` §5 und `.claude/rules/DESIGN-SYSTEM.md` über die geänderten Dateien. Im PR-Text steht, was geprüft wurde und was Jo am Gerät prüfen muss.
- `docs/plan/` ist Jos unversionierter Ordner und wird nicht angefasst oder committet.
- Nach dem Öffnen jedes PRs: Skill `copilot-pr-review` anwenden.

## Review Focus

1. Koordinate nahe 0 mit negativem Vorzeichen (z.B. Länge −0,0000001): kopiert wird `0.000000`, nicht `-0.000000`. → Test in Task 1.
2. UTM/MGRS außerhalb des gültigen Bereichs (Polregion): die Anzeige fällt auf Dezimalgrad zurück, die Kopie muss das auch tun statt nichts zu kopieren. → Test in Task 1.
3. Gerät mit Gebietsschema `de_DE`: die Kopie hat trotzdem Dezimalpunkte. → Test in Task 1.
4. Probe in einer Zeitzone, in der der lokale Tag vom UTC-Tag abweicht: Wochentag und Datum der Datumszeile gehören zum lokalen Tag der Probe. → Test in Task 4.
5. Zweimal schnell hintereinander kopieren (erst Koordinate, dann Höhe): der Hinweis „Kopiert“ steht nur am zuletzt getippten Wert und verschwindet nach Ablauf; ein früher gestarteter Timer blendet den neuen Hinweis nicht vorzeitig aus. → Schritt in Task 2 (von Hand im Simulator prüfen, kein Unit-Test).

---

## PR 1 – `feat/sample-copy-coordinate`

### Task 1: Zwischenablage-Texte als pure Funktion

**Files:**
- Create: `ios/Packages/LegulusGeo/Sources/LegulusGeo/ClipboardText.swift`
- Test: `ios/Packages/LegulusGeo/Tests/LegulusGeoTests/ClipboardTextTests.swift`

**Interfaces:**
- Consumes: `CoordinateConverter.format(lat:lon:as:) -> String?`, `CoordinateDisplayFormat` (bestehend).
- Produces:
  - `public enum ClipboardText`
  - `public static func coordinate(lat: Double, lon: Double, format: CoordinateDisplayFormat) -> String?`
  - `public static func altitude(meters: Double) -> String`

Regeln: `.utm` und `.mgrs` → Ergebnis von `CoordinateConverter.format` ohne Whitespace; liefert das `nil`, Rückfall auf Dezimalgrad. Alle anderen Formate → Dezimalgrad mit Vorzeichen, 6 Nachkommastellen, `"lat,lon"`, Locale `en_US_POSIX`, negative Null wird zu `0.000000`. Nicht-endliche Eingaben → `nil`. Höhe → auf ganze Meter gerundet plus `m` ohne Leerzeichen.

- [ ] **Step 1: Branch anlegen**

```bash
git fetch origin && git switch -c feat/sample-copy-coordinate origin/main
```

- [ ] **Step 2: Failing Tests schreiben** (`ClipboardTextTests`, `ne` wie in `CoordinateConverterTests` definieren)

```swift
func testGeographicFormatsCopyDecimalDegrees() {
    let geographic: [CoordinateDisplayFormat] = [
        .decimalSign, .decimalDirection, .degreesSign, .degreesDirection,
        .degreesMinutesSign, .degreesMinutesDirection, .dmsSign, .dmsDirection
    ]
    for format in geographic {
        XCTAssertEqual(ClipboardText.coordinate(lat: 49.1234, lon: 10.1234, format: format),
                       "49.123400,10.123400", "\(format)")
    }
}
func testSouthWestIsNegative() {
    XCTAssertEqual(ClipboardText.coordinate(lat: -33.865143, lon: -151.2099, format: .dmsDirection),
                   "-33.865143,-151.209900")
}
func testNegativeZeroIsPlainZero() {
    XCTAssertEqual(ClipboardText.coordinate(lat: 0, lon: -0.0000001, format: .decimalSign),
                   "0.000000,0.000000")
}
func testUTMAndMGRSDropWhitespace() {
    XCTAssertEqual(ClipboardText.coordinate(lat: ne.lat, lon: ne.lon, format: .utm), "32U5744005503700")
    let mgrs = ClipboardText.coordinate(lat: ne.lat, lon: ne.lon, format: .mgrs)
    XCTAssertEqual(mgrs?.contains(" "), false)
    XCTAssertEqual(mgrs?.hasPrefix("32UNA744"), true)
    XCTAssertEqual(mgrs?.count, 15)
}
func testGridFormatOutOfRangeFallsBackToDecimal() {
    // lat 89 liegt außerhalb des UTM/MGRS-Bereichs
    XCTAssertEqual(ClipboardText.coordinate(lat: 89, lon: 10, format: .mgrs), "89.000000,10.000000")
}
func testNonFiniteIsNil() {
    XCTAssertNil(ClipboardText.coordinate(lat: .nan, lon: 0, format: .decimalSign))
}
func testAltitude() {
    XCTAssertEqual(ClipboardText.altitude(meters: 275.6), "276m")
    XCTAssertEqual(ClipboardText.altitude(meters: -3.2), "-3m")
}
```

Falls `CoordinateConverter.format(lat: 89, …, as: .mgrs)` nicht `nil` liefert, im Test eine Koordinate wählen, für die es `nil` ist, und das im Testkommentar begründen.

- [ ] **Step 3: Tests laufen lassen, Fehlschlag bestätigen** (Kompilierfehler „cannot find 'ClipboardText'“). Paket-Tests laufen über `bash scripts/check-ios.sh` bzw. das dort verwendete `xcodebuild test`.

- [ ] **Step 4: `ClipboardText` implementieren** (Doc-Comment am Typ: wofür, wann). Der Locale-Test aus Review Focus 3 ist durch `String(format:locale:)` mit `en_US_POSIX` abgedeckt; zusätzlich Test `testDecimalPointIndependentOfLocale` ergänzen, falls die Implementierung `NumberFormatter` nutzt.

- [ ] **Step 5: Tests grün**

- [ ] **Step 6: Commit** `feat(ios): Zwischenablage-Texte für Koordinate und Höhe`

### Task 2: Kopier-Buttons in der Standortzeile

**Files:**
- Create: `ios/Legulus/Features/SampleEditor/CopyableValueButton.swift`
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` (`locationRow`, `coordinateBlock`, `altitudeBlock`, `locationA11yLabel`)

**Interfaces:**
- Consumes: `ClipboardText.coordinate(lat:lon:format:)`, `ClipboardText.altitude(meters:)`, `config.coordinateDisplayFormat`, `viewModel.coordinate`, `viewModel.altitudeM`.
- Produces: `struct CopyableValueButton<Content: View>: View` mit `init(caption: String, clipboardText: String, accessibilityLabel: String, announcement: String, alignment: HorizontalAlignment, @ViewBuilder content: () -> Content)`.

Verhalten von `CopyableValueButton`:
- Echter `Button` mit `.buttonStyle(.plain)`, Inhalt: Caption-Zeile (`AppFont.footnote`, sekundär) über `content`. `frame(minWidth: 44, minHeight: 44)`, `contentShape(Rectangle())`.
- Tap: `UIPasteboard.general.string = clipboardText`; für 1,5 s zeigt die Caption-Zeile `Label("Kopiert", systemImage: "checkmark")` statt der Caption (gleiche Zeile, kein Layout-Sprung); Übergang über `AppMotion.respecting(AppMotion.fast, reduceMotion:)`; `.sensoryFeedback(.success, trigger:)`; `AccessibilityNotification.Announcement(announcement).post()`.
- Rücksetzen über eine `Task`, die bei erneutem Tap abgebrochen und neu gestartet wird.
- `.accessibilityLabel(accessibilityLabel)`, `.accessibilityHint("Kopiert in die Zwischenablage")`.
- `#Preview` in Default, AX5 und Dark.

Verdrahtung in `SampleEditorView`:
- `locationRow`: `.accessibilityElement(children: .combine)` und `.accessibilityLabel(locationA11yLabel)` entfernen. `GPSStatusIcon` bleibt.
- `coordinateBlock`: mit Koordinate → `CopyableValueButton` (Caption = `coordinateDisplay.caption`, Inhalt = Koordinatentext; Genauigkeitszeile bleibt Text unter dem Button). Label: `"Koordinate \(text), \(caption)"` plus `", Genauigkeit etwa N Meter"`, wenn vorhanden. Ansage: `"Koordinate kopiert"`. Ohne Koordinate: wie bisher reiner Text.
- `altitudeBlock`: mit `viewModel.altitudeM` → `CopyableValueButton` (Caption „Höhe“). Label: `"Höhe N Meter"` plus `", Fehler etwa N Meter"`. Ansage: `"Höhe kopiert"`. Ohne Höhe: Text „—“ wie bisher, mit `accessibilityLabel("Höhe unbekannt")`.
- `locationA11yLabel` entfällt, sobald es keinen Aufrufer mehr hat.
- Das UI-Test-Prädikat `label CONTAINS '49.68'` in `LegulusUITests/SampleFlowTests.swift:52` muss weiter treffen (Koordinatentext steht im Label).

- [ ] **Step 1: `CopyableValueButton` anlegen** (Doc-Comment, Previews)
- [ ] **Step 2: `SampleEditorView` umbauen** wie oben
- [ ] **Step 3: Build und Tests:** `bash scripts/check-ios.sh` → grün, inklusive `SampleFlowTests` und `AccessibilityAuditTests`
- [ ] **Step 4: Im Simulator prüfen:** Koordinate tippen → in Notizen einfügen ergibt das erwartete Format; Format in den Einstellungen auf MGRS und UTM stellen und wiederholen; Koordinate und direkt danach Höhe tippen (Review Focus 5); AX5: nichts abgeschnitten, Blöcke stapeln sich
- [ ] **Step 5: Anti-Pattern-Greps** über die zwei Dateien, Treffer beheben
- [ ] **Step 6: Commit** `feat(ios): Koordinate und Höhe per Tap kopieren`
- [ ] **Step 7: Push und PR** (`gh pr create --base main`), Titel wie Commit. PR-Text: was, warum, geprüfte Stufen, Prüfschritte für Jo (VoiceOver am Gerät: zwei Buttons, Ansage nach dem Kopieren). Danach `copilot-pr-review`.

---

## PR 2 – `feat/sample-toolbar-edit-icon`

### Task 3: Stift-Icon, Stern und Kamera in den Inhalt

**Files:**
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` (`.toolbar`, `editableSection`, `photoStrip`)
- Modify: `PHASES.md` (neuer Abschnitt)
- Add: `docs/superpowers/specs/2026-11-18-sample-ansicht-design.md`, `docs/superpowers/plans/2026-11-19-sample-ansicht-kleine-prs.md`

**Interfaces:**
- Consumes: `openForm()`, `viewModel.toggleMarked(endpoint:auth:)`, `showingCamera`, `viewModel.isExistingSample`, `viewModel.savedSample`.
- Produces: private `var photoSection: some View` in `SampleEditorContent` (Kopfzeile „Fotos“ + Kamera-Button + Strip). PR 4 ersetzt später die Aktion des Kamera-Buttons.

- [ ] **Step 1: Branch** `git switch -c feat/sample-toolbar-edit-icon origin/main`
- [ ] **Step 2: Doku-Commit.** Spec und diesen Plan hinzufügen. In `PHASES.md` einen Abschnitt „Phase S – Sample-Ansicht“ mit sechs offenen Punkten anlegen (ein Punkt je PR 1 bis 6, mit Branch-Namen) und die Statuszeile oben um „Phase S in Arbeit“ ergänzen. Commit `docs: Design und Plan für Sample-Ansicht (Phase S)`.
- [ ] **Step 3: Toolbar.** Rechts bleibt genau ein `ToolbarItem(placement: .topBarTrailing)`, nur wenn `viewModel.isExistingSample`: `Button(action: openForm) { Image(systemName: "pencil") }` mit `.accessibilityLabel("Bearbeiten")` und dem bestehenden Hint. Die Toolbar-Einträge für Kamera und Stern entfallen. Der Zurück-Button links bleibt unverändert.
- [ ] **Step 4: Stern neben der Sample-Nummer.** In `editableSection` das `TextField` in einen `HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm)` setzen; rechts, nur bei gespeicherter Probe, der Stern-Button mit unveränderter Aktion, Icons `star.fill`/`star`, Labels „Markierung entfernen“/„Probe markieren“, `frame(minWidth: 44, minHeight: 44)`, `contentShape(Rectangle())`. Der markierte Zustand ist an der Form erkennbar (gefüllt/leer), nicht nur an der Farbe.
- [ ] **Step 5: Foto-Bereich.** `photoSection`: `HStack` mit `Text("Fotos")` (Stil und Header-Trait wie „Notizen“), `Spacer`, Kamera-Button (`Image(systemName: "camera.fill")`, `.accessibilityLabel("Foto aufnehmen")`, 44 × 44 pt, Aktion `showingCamera = true`); darunter `photoStrip`, wenn Fotos vorhanden sind. `photoSection` wird immer gezeigt und ersetzt den bedingten `photoStrip`-Aufruf.
- [ ] **Step 6: Build und Tests:** `bash scripts/check-ios.sh` → grün
- [ ] **Step 7: Im Simulator prüfen (iOS 18 und iOS 26):** rechts oben steht nur der Stift, kein „…“; Tap öffnet das Formular; Stern schaltet um; Kamera-Button öffnet den Picker; AX5: Sample-Nummer und Stern überlappen nicht
- [ ] **Step 8: Anti-Pattern-Greps**, dann Commit `feat(ios): Stift-Icon statt Bearbeiten-Menü in der Sample-Ansicht`
- [ ] **Step 9: Push, PR, `copilot-pr-review`.** PR-Text nennt, dass PR 4 auf diesem Branch aufbaut.

---

## PR 3 – `feat/sample-date-row`

### Task 4: Kalender-Icon und Umbruch nach dem Wochentag

**Files:**
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorViewModel.swift` (neue statische Funktion neben `timeWindowText`)
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` (`timeRow`, `moonSymbol`, `dayFormatter`, `longDateText`)
- Test: `ios/LegulusTests/SampleDateRowTests.swift`

**Interfaces:**
- Produces: `static func longDateParts(_ date: Date, zone: TimeZone) -> (weekday: String, date: String)` an `SampleEditorViewModel`; Locale `de_DE`, Formate `"EEEE,"` und `"dd. MMMM yyyy"`.

- [ ] **Step 1: Branch** `git switch -c feat/sample-date-row origin/main`
- [ ] **Step 2: Failing Tests**

```swift
func testLongDateParts_Berlin() throws {
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z"))
    let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
    let parts = SampleEditorViewModel.longDateParts(date, zone: zone)
    XCTAssertEqual(parts.weekday, "Montag,")
    XCTAssertEqual(parts.date, "16. November 2026")
}
func testLongDateParts_UsesLocalDayOfZone() throws {
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T23:30:00Z"))
    let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
    let parts = SampleEditorViewModel.longDateParts(date, zone: zone)
    XCTAssertEqual(parts.weekday, "Dienstag,")
    XCTAssertEqual(parts.date, "17. November 2026")
}
```

- [ ] **Step 3: Fehlschlag bestätigen**, dann `longDateParts` implementieren, Tests grün
- [ ] **Step 4: `timeRow` umbauen.**
  - Icon: `Image(systemName: "calendar")`, sonst wie bisher (dekorativ, `accessibilityHidden`). `moonSymbol` löschen.
  - Datum: `ViewThatFits(in: .horizontal)` mit erstens `Text("\(parts.weekday) \(parts.date)").lineLimit(1)` und zweitens `VStack(alignment: .leading, spacing: AppSpacing.xxs) { Text(parts.weekday); Text(parts.date) }`. `.lineLimit(2)` und `.minimumScaleFactor(0.9)` am alten Text entfallen; der zweite Zweig hat kein Zeilenlimit.
  - `longDateText` bleibt für `timeA11yLabel` und wird aus den beiden Teilen zusammengesetzt; `dayFormatter` entfällt, wenn ungenutzt.
  - Zone wie bisher: Zone der Probe, bei neuer Probe Gerätezone und aktuelles Datum.
- [ ] **Step 5: Build und Tests:** `bash scripts/check-ios.sh` → grün
- [ ] **Step 6: Im Simulator prüfen:** Standardgröße einzeilig; ab der Größe, bei der es nicht mehr passt, „Montag,“ über „16. November 2026“; AX5 ohne Clipping; Uhrzeitbereich darunter
- [ ] **Step 7: Anti-Pattern-Greps**, Commit `feat(ios): Kalender-Icon und Umbruch nach dem Wochentag in der Datumszeile`
- [ ] **Step 8: Push, PR, `copilot-pr-review`**

---

## PR 5 – `feat/sample-code-font`

### Task 5: Kleinere Schrift für die Sample-Nummer

**Files:**
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` (`editableSection`, `TextField("Code", …)`)

- [ ] **Step 1: Branch** `git switch -c feat/sample-code-font origin/main`
- [ ] **Step 2:** `.font(.title2.weight(.semibold).monospaced())` durch `.font(AppFont.codeEmphasized)` ersetzen
- [ ] **Step 3: Build und Tests:** `bash scripts/check-ios.sh` → grün. Schlägt ein Snapshot-Test der Sample-Ansicht fehl, Referenzbild prüfen, neu aufnehmen und mitcommitten.
- [ ] **Step 4: Im Simulator prüfen:** Standardgröße und AX5; das Feld bleibt mindestens 44 pt hoch antippbar
- [ ] **Step 5: Commit** `feat(ios): kleinere Schrift für die Sample-Nummer`
- [ ] **Step 6: Push, PR, `copilot-pr-review`**

---

## Nach dem Merge

Die PRs 1, 3 und 5 berühren andere Stellen derselben Datei als PR 2. Entsteht nach einem Merge ein Konflikt, den jeweiligen Branch auf `origin/main` rebasen und `bash scripts/check-ios.sh` erneut laufen lassen. In `PHASES.md` die erledigten Punkte von Phase S abhaken, sobald PR 2 gemerged ist (die anderen PRs fassen `PHASES.md` nicht an).
