# Sofort-Anlage, Hintergrund-Ortung, Feature-Flags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Sample sofort beim Tippen anlegen, Editor im Navigation-Stack mit Speichern beim Zurück, Hintergrund-Ortung bis zum Fix, Flipt-Feature-Flags.

**Architecture:** Neues Sample wird im HomeViewModel angelegt und als bestehendes Sample im Editor geöffnet; ein container-eigener `PendingFixService` ortet bis zum Fix weiter und schreibt die Koordinate über `LocalSampleStore.updateCoordinate`. Sample-Löschen läuft über die Outbox (`op .delete`). Flipt hinter einem Protokoll, damit Tests ohne Netz laufen.

**Tech Stack:** SwiftUI, GRDB, CoreLocation, SPM `flipt-client-swift` 1.5.5.

**Spec:** `docs/superpowers/specs/2026-11-10-sofort-anlage-design.md`

## Global Constraints

- Phase heißt in `PHASES.md` „Phase E – Sofort-Anlage, Hintergrund-Ortung, Feature-Flags“.
- Branch `feat/sofort-anlage` im Haupt-Checkout `/Users/jbrunner/work/projects/fieldworksdiary-ng`. **Keine git worktrees.**
- Conventional Commits; jede Message endet mit Leerzeile + `Claude-Session: https://claude.ai/code/session_015iSEsSrMrE4BRew7xJkVcS`. Nicht pushen. Dateien explizit stagen; nie `ios/Fieldworksdiary/Resources/Localizable.xcstrings`-Umformatierungsrauschen oder `ios/FieldworksdiaryTests/PendingMutationsStoreTests.swift` (Jos lokale Änderung) mitnehmen, außer eigene String-Ergänzungen.
- UI-Texte exakt: „Die Sample-ID darf nicht leer sein und muss eindeutig sein.“ · „Diese Sample-ID ist bereits vergeben.“ · Buttons „Abbrechen“ (löscht das neue Sample, `role: .destructive`, Titel „Sample löschen“), „Korrigieren“, „Bisherige ID behalten“.
- Ortungs-Limit 5 Minuten pro Sample; Genauigkeitsschwelle = die bestehende Editor-Schwelle (im Code nachsehen, nicht neu erfinden).
- Flipt: `https://ff.fieldworksdiary.org`, Environment/Namespace `default`, keine Auth, Entity-ID = User-ID, Kontext `platform`, `app_version`; Fallback `false`.
- iOS-Regeln: `.claude/rules/DESIGN-SYSTEM.md`, `ACCESSIBILITY-IOS.md`, `LOGGING.md` (keine Koordinaten loggen). Keine Force-Unwraps.
- Typecheck: `cd ios && xcodegen generate && xcodebuild build-for-testing -project Fieldworksdiary.xcodeproj -scheme Fieldworksdiary -destination 'generic/platform=iOS Simulator' -IDEBuildingContinueBuildingAfterErrors=YES CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error:' | grep -v 'objc_abi_version\|Linker command failed'` → leer. App-Tests führt der Controller über Xcode aus.

## Review Focus

1. Abbruch bei leerer ID, nachdem der Create schon gepusht wurde → Sample auch auf dem Server gelöscht, keine verwaisten Fotos/Bestimmungen/Features.
2. Fix kommt, während der Editor offen ist und der User gerade Notizen tippt → Koordinate wird gesetzt, Notizen gehen beim Zurück nicht verloren (kein Überschreiben mit veraltetem Stand).
3. Zwei Samples in 30 s angelegt → jedes bekommt einen eigenen Fix, keiner wird doppelt geschrieben.
4. App wird mit offenem Editor beendet (Hintergrund) → Eingaben sind gespeichert.
5. Kein Netz beim Start → `FeatureFlags.isEnabled` liefert `false`, kein Absturz, kein Blockieren.

---

### Task 0: Phasenstatus (Controller)
- [ ] `PHASES.md`: Abschnitt „Phase E – …“ mit Status in progress, Spec/Plan-Links, Tasks 1–5. Commit `docs(phases): Phase E eingetragen`.

### Task 1: Sample löschen über die Outbox
**Files:** `Core/Persistence/LocalSampleStore.swift`, `Core/Sync/SyncRunner.swift` (+ Client-Methode für `DELETE /api/collections/samples/records/{id}`), Tests.
**Produces:** `func deleteSample(id: String, mutationsStore: PendingMutationsStore) throws` — löscht lokal Sample + Fotos (inkl. Dateien) + Bestimmungen + Feature-Zeilen; noch nicht gepusht → offene Mutationen des Samples entfernen, nichts an den Server; schon gepusht → `.sample/.delete`-Mutation mit Backend-ID. SyncRunner führt `.delete` aus (404 = Erfolg).
- [ ] Tests: lokal-only gelöscht ohne Mutation; gepusht → Delete-Mutation, SyncRunner ruft DELETE, 404 gilt als erledigt; abhängige Zeilen weg.
- [ ] Commit `feat(sync): Samples lokal und auf dem Server löschen`.

### Task 2: PendingFixService und Ortungsberechtigung „Immer“
**Files:** Create `Core/Location/PendingFixService.swift`; Modify `LocationProvider.swift` (ggf. Abstraktion), `App/AppContainer.swift`, `ios/project.yml`/`Info.plist`/`Info.debug.plist` (`NSLocationAlwaysAndWhenInUseUsageDescription` deutsch, `UIBackgroundModes: [location]`), Tests.
**Produces:** `@MainActor final class PendingFixService` mit `func register(sampleID: String, createdAt: Date)`, `func resumePending()` (beim Vordergrund: Samples ohne Koordinate mit createdAt < 5 min), injizierbarer Fix-Quelle und Uhr. Schreibt den ersten brauchbaren Fix je Sample über `LocalSampleStore.updateCoordinate` (bestehender Pfad, löst Ortsauflösung + Sync aus); überspringt Samples, die inzwischen eine Koordinate haben (z. B. per Karte gesetzt). Nach 5 min aufgeben (Log). Hintergrund-Updates nur mit Berechtigung „Immer“ (`allowsBackgroundLocationUpdates`, `pausesLocationUpdatesAutomatically = false`), Ortung stoppen, wenn nichts mehr offen ist. Berechtigung: nach `whenInUse` einmalig `requestAlwaysAuthorization()`.
- [ ] Tests (Fake-Quelle + Fake-Uhr): ein Fix für zwei registrierte Samples → beide bekommen ihn genau einmal; Sample mit manueller Koordinate wird übersprungen; Timeout nach 5 min; ungenauer Fix wird ignoriert.
- [ ] Commit `feat(location): Hintergrund-Ortung bis zum Fix je Sample`.

### Task 3: Sofort-Anlage und Editor im Navigation-Stack
**Files:** `Features/Home/HomeView.swift`, `HomeViewModel.swift`, `Features/SampleEditor/SampleEditorView.swift`, `SampleEditorViewModel.swift`, `LocalSampleStore.swift` (`createLocal` ohne Koordinate erlauben, falls nötig), Tests, `Localizable.xcstrings` (nur eigene Strings).
**Consumes:** Task 1 `deleteSample`, Task 2 `PendingFixService.register`.
- „Sample anlegen“ → `HomeViewModel.createSample()` legt sofort an (GPS-Fix, falls schon vorhanden, sonst ohne Koordinate + `register`), queued den Create und kickt den Sync, dann Push von `SampleEditorView(sampleID:, isNew: true)` per `navigationDestination`. `AddSampleSheet` entfällt.
- Editor: `saveButton`, „Sichern“, Discard-Dialog entfallen. Eigener Back-Button (Chevron + „Zurück“, VoiceOver-Label „Zurück“) ruft `finishEditing()`: speichert geänderte Felder (bestehendes `saveEdits`-Muster mit Re-Read, nur geänderte Felder überlagern), validiert ID (Spec Ziel 3), dann `dismiss`. Swipe-back: deaktivieren oder ebenfalls über `finishEditing` leiten. `scenePhase == .background` → speichern ohne Validierungsdialog (leere/doppelte ID bleibt bis zum Zurück stehen).
- Ein im Editor eintreffender Fix aktualisiert die Koordinatenanzeige, ohne Nutzereingaben zu verwerfen.
- [ ] Tests: createSample legt Sample + Create-Mutation an; finishEditing speichert Notizen; leere ID bei neuem Sample → Validierungszustand; Abbrechen → deleteSample; doppelte ID → Zustand mit beiden Optionen, „Bisherige ID behalten“ speichert Rest; bestehendes Sample mit leerer ID → kein Dialog.
- [ ] Commit `feat(ios): Sample sofort anlegen, Editor speichert beim Zurück`.

### Task 4: Feature-Flags mit Flipt
**Files:** `ios/project.yml` (Package `https://github.com/flipt-io/flipt-client-swift`, exactVersion `1.5.5`, Produkt `FliptClient`), Create `Core/FeatureFlags/FeatureFlags.swift`, `AppConfig.swift` (`featureFlagsURL`), `AppContainer.swift`, `SettingsView.swift` (Debug-Abschnitt „Feature-Flags“ unter `#if DEBUG`), Tests.
**Produces:** `protocol FeatureFlagEvaluating { func isEnabled(_ key: String, entityID: String, context: [String: String]) -> Bool; func flagKeys() -> [String] }`, Flipt-Adapter, `@MainActor final class FeatureFlags { func isEnabled(_ key: String) -> Bool }` (Fehler/kein Client → `false`, nie blockierend; Client-Aufbau im Hintergrund, Polling 120 s).
- [ ] Tests mit Fake-Evaluator: Fallback false ohne Client; Weitergabe von Entity-ID und Kontext.
- [ ] Commit `feat(ios): Feature-Flags über Flipt`.

### Task 5: Phase E abschließen (Controller)
- [ ] Xcode-Suite grün, Typecheck leer; PHASES.md „implementiert, wartet auf Test durch Jo“.
