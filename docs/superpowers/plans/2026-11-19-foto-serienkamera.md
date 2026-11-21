# Serienkamera und Fotos im Original (PR 4 und PR 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Belegfotos lassen sich in Serie aufnehmen, werden unverändert (volle Auflösung, JPEG, alle EXIF-Daten samt Aufnahmeposition) gespeichert und hochgeladen, lassen sich löschen, und der Foto-Import beim Nachtragen behält Auflösung und Metadaten.

**Architecture:** Eine eigene Kamera auf AVFoundation liefert die JPEG-Datei, die `PhotoStorage` bytegleich ablegt. Fotos werden sofort als `LocalPhoto` gespeichert; der `SyncRunner` lädt sie in jedem Durchlauf hoch, unabhängig von einer Änderung an der Probe, und führt Lösch-Mutationen aus. Reine Logik (Dateiformat, GPS-Metadaten, Upload-Entscheidung) liegt in testbaren Typen ohne Kamera und Netz.

**Tech Stack:** Swift, SwiftUI, AVFoundation, ImageIO, GRDB, XCTest; Backend: Go, PocketBase.

**Spec:** `docs/superpowers/specs/2026-11-18-sample-ansicht-design.md`, Features 4 und 6.

## Global Constraints

- PR 4: Branch `feat/sample-photo-series` von `origin/main` (PR 2 ist gemergt, kein Stapeln mehr nötig). PR 6: Branch `feat/retrospective-photo-original` auf PR 4.
- Commits: Conventional Commits, Scope `ios` bzw. `tabularius`, Footer `Claude-Session: https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`; PR-Text endet mit `https://claude.ai/code/session_015iSEsSvdpvRcSFALTnRzYp`.
- Schreiben geht immer zuerst lokal; kein UI-Pfad wartet auf das Netz.
- Ein aufgenommenes Foto darf nie stillschweigend verloren gehen: Schreibfehler erscheinen als sichtbare Meldung in der Kamera.
- Fotodateien werden nie neu kodiert oder verkleinert, außer beim einmaligen Wandeln eines Nicht-JPEG-Imports (PR 6, Qualität 0.92, volle Pixelgröße, Metadaten übernommen).
- Auflösung der Kamera: Standard-Fotoauflösung des Geräts, kein 48-MP-Modus.
- Backend-Limit `sample_photos.photo_file`: 50 MB.
- Upload-Fehler werden nur geloggt (`Log.sync`), keine Anzeige am Foto.
- Logging nur über `Log.<category>`, keine Koordinaten mit vollen Nachkommastellen, kein `print()`. Keine Force-Unwraps.
- A11y (`.claude/rules/ACCESSIBILITY-IOS.md`) und Design-System (`.claude/rules/DESIGN-SYSTEM.md`): Tokens und Atoms, 44 × 44 pt, Labels an Icon-Buttons, Dynamic Type bis AX5, Reduce Motion.
- Nach jedem Branch-Wechsel und nach jeder neuen Datei: `cd ios && xcodegen generate`.
- Vor jedem PR: `bash scripts/check-ios.sh` grün (und `cd tabularius && go test ./... && golangci-lint run` für den Backend-Teil); Anti-Pattern-Greps über die geänderten Dateien. Im PR-Text steht, was am Gerät zu prüfen ist. Danach `copilot-pr-review`.
- Keine echten Dienst-Adressen in Doku, Tests, Commit- oder PR-Texten.

## Review Focus

1. App geht während einer Serie in den Hintergrund oder wird beendet: jedes bestätigte Foto liegt auf der Platte und in `local_photos`. → Fotos werden pro Auslösung sofort geschrieben; Test in Task 5.
2. Speicher voll oder Schreibfehler: sichtbare Meldung, kein Zähler-Sprung, kein Eintrag ohne Datei. → Test in Task 5.
3. Foto wird gelöscht, während sein Upload läuft: es entsteht kein verwaister Datensatz auf dem Server. → Test in Task 6.
4. Derselbe Upload wird nach einem Timeout wiederholt: kein doppeltes Foto am Sample. → Backend-Test in Task 1, Client-Test in Task 6.
5. „Nur im WLAN“ aktiv und nur Mobilfunk: Fotos warten, Sample-Daten syncen trotzdem; Wechsel ins WLAN lädt nach. → Test in Task 6.

---

## PR 4

### Task 1: Backend – größeres Limit und idempotenter Upload

**Files:**
- Create: `tabularius/migrations/1700000030_phase_s_photo_limit.go` (+ `_test.go`)
- Create: `tabularius/internal/hooks/photo_idempotency.go` (+ `_test.go`)
- Modify: `tabularius/main.go` (Registrierung)

**Interfaces:**
- Produces: `hooks.RegisterPhotoIdempotency(app core.App)` — Create-Request-Hook auf `sample_photos`: existiert für denselben Besitzer schon ein Datensatz mit derselben nicht leeren `client_uuid`, antwortet der Hook mit diesem Datensatz (200) und legt nichts an.
- Migration: `photo_file.MaxSize = 50 * 1024 * 1024`; Down setzt 10 MB.

- [ ] Failing Tests: `TestPhaseSPhotoLimit` (Feld hat 50 MB, Down 10 MB); `TestPhotoCreate_SameClientUUIDReturnsExisting` (zwei Creates, ein Datensatz, zweite Antwort trägt die ID des ersten); `TestPhotoCreate_OtherOwnerSameUUIDCreates`; `TestPhotoCreate_EmptyUUIDAlwaysCreates`.
- [ ] Implementieren, `go test ./...`, `golangci-lint run`.
- [ ] Commit `feat(tabularius): 50-MB-Limit und idempotenter Upload für Sample-Fotos`

### Task 2: `PhotoStorage` für fertige Dateien und Vorschaubilder

**Files:**
- Modify: `ios/Legulus/Core/Photos/PhotoStorage.swift`
- Test: `ios/LegulusTests/PhotoStorageTests.swift`

**Interfaces:**
- Produces:
  - `static func write(data: Data, sampleID: String, photoID: String) throws -> String` — schreibt die Bytes unverändert nach `photos/<sampleID>/<photoID>.jpg`, atomar; gibt den relativen Pfad zurück.
  - `static func thumbnail(relativePath: String, maxPixel: CGFloat) -> UIImage?` — verkleinerte Vorschau per `CGImageSourceCreateThumbnailAtIndex` (mit `kCGImageSourceCreateThumbnailWithTransform`), ohne das volle Bild zu dekodieren.
  - `static func fileSize(relativePath: String) -> Int64?`
- Der bisherige Weg `write(image:…)` bleibt bis PR 6 bestehen.

- [ ] Failing Tests: `testWriteData_KeepsBytesIdentical` (gelesene Datei == geschriebene Daten), `testWriteData_OverwritesAtomically`, `testThumbnail_IsDownscaledAndUpright` (Quelle 4000 × 3000 mit EXIF-Orientierung 6 → längste Kante ≤ `maxPixel`, Hochformat), `testThumbnail_MissingFileIsNil`.
- [ ] Implementieren; Tests grün.
- [ ] Commit `feat(ios): Fotodateien unverändert speichern, Vorschau ohne Volldekodierung`

### Task 3: GPS-Metadaten für die Aufnahme

**Files:**
- Create: `ios/Legulus/Core/Photos/PhotoGPSMetadata.swift`
- Test: `ios/LegulusTests/PhotoGPSMetadataTests.swift`

**Interfaces:**
- Produces: `enum PhotoGPSMetadata { static func dictionary(for location: CLLocation) -> [String: Any] }` — Inhalt für `kCGImagePropertyGPSDictionary`: Breite/Länge als positive Werte mit `LatitudeRef` N/S und `LongitudeRef` E/W, Höhe mit `AltitudeRef` (0 über, 1 unter Meereshöhe) nur bei gültiger vertikaler Genauigkeit, `HPositioningError` bei gültiger horizontaler Genauigkeit, `DateStamp` (`yyyy:MM:dd`) und `TimeStamp` (`HH:mm:ss`) in UTC.

- [ ] Failing Tests: Nord/Ost, Süd/West (positive Werte, Ref S/W), Höhe unter null, ungültige Genauigkeiten lassen die Felder weg, UTC-Zeitstempel unabhängig von der Gerätezone.
- [ ] Implementieren; Commit `feat(ios): GPS-Metadaten für Kamerafotos`

### Task 4: Kamera

**Files:**
- Create: `ios/Legulus/Features/Camera/CameraSession.swift`, `CameraView.swift`, `CameraPreview.swift`
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` (Kamera-Button öffnet `CameraView`; im Simulator weiter `CameraPicker`)
- Test: `ios/LegulusTests/CameraSessionLogicTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class CameraSession: NSObject, ObservableObject` mit
    - `enum State: Equatable { case idle, unauthorized, unavailable, running, failed(String) }`, `@Published private(set) var state`
    - `@Published private(set) var isCapturing: Bool`, `@Published var flashMode: AVCaptureDevice.FlashMode` (`.auto`/`.off`)
    - `func start() async`, `func stop()`, `func capture()`, `func focus(at devicePoint: CGPoint)`, `func zoom(by factor: CGFloat)`, `func zoomEnded()`
    - `var onPhoto: ((Data) -> Void)?` — die Bytes aus `AVCapturePhoto.fileDataRepresentation()`
    - `var locationProvider: (() -> CLLocation?)?` — Standort für die GPS-Metadaten der nächsten Aufnahme
  - `struct CameraView: View` mit `init(onPhoto: @escaping (Data) throws -> Void, onDone: @escaping () -> Void)`.
  - Pure Helfer (testbar): `CameraSession.preferredDeviceTypes: [AVCaptureDevice.DeviceType]` (Reihenfolge: `.builtInTripleCamera`, `.builtInDualWideCamera`, `.builtInDualCamera`, `.builtInWideAngleCamera`), `static func clampedZoom(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat` (Obergrenze zusätzlich 10), `static func photoSettings(flash:supportedFlash:location:) -> AVCapturePhotoSettings` (JPEG-Codec, Blitz nur wenn unterstützt, `metadata` mit dem GPS-Block aus Task 3).

Verhalten:
- Session-Preset `.photo`, `maxPhotoDimensions` bleibt auf dem Standard des aktiven Formats (kein 48 MP), `photoQualityPrioritization = .balanced`.
- Ausrichtung über `AVCaptureDevice.RotationCoordinator` (`videoRotationAngleForHorizonLevelCapture` an der Foto-Verbindung).
- Die Kamera bleibt nach jeder Aufnahme offen. Während `isCapturing` ist der Auslöser gesperrt.
- `CameraView`: Vollbild, Vorschau, Auslöser (≥ 72 pt), „Fertig“, Blitz-Umschalter, Zähler der Sitzung, Vorschau des letzten Bildes. Pinch zoomt, Tap fokussiert. Ortung läuft während der Sitzung über den bestehenden `LocationProvider` (`requestFix()` beim Start); das Auslösen wartet nie auf einen Fix.
- Wirft `onPhoto`, zeigt die Kamera die Fehlermeldung als Banner und zählt nicht hoch.
- `.unauthorized`: Text mit Button „Einstellungen öffnen“ (`UIApplication.openSettingsURLString`). `.unavailable` (Simulator): die Sample-Ansicht öffnet stattdessen den bisherigen `CameraPicker`.
- A11y: Labels „Foto aufnehmen“, „Fertig“, „Blitz: automatisch/aus“, Zähler als Wert des Auslösers; nach jeder Aufnahme Ansage „Foto N aufgenommen“; Bedienelemente lesbar bis AX5 (Texte umbrechen, Icons mit `@ScaledMetric`).

- [ ] Failing Tests für die puren Helfer: Reihenfolge der Gerätetypen, `clampedZoom` (unter Minimum, über Maximum, über 10), `photoSettings` (Codec JPEG; Blitz `.auto` wird `.off`, wenn nicht unterstützt; GPS-Block vorhanden mit Standort, fehlt ohne).
- [ ] Implementieren; Build grün; Anti-Pattern-Greps.
- [ ] Commit `feat(ios): Serienkamera für Belegfotos`

### Task 5: Fotos sofort speichern, Strip mit Vorschau und Löschen

**Files:**
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorViewModel.swift`, `SampleEditorView.swift`
- Modify: `ios/Legulus/Core/Persistence/LocalPhotoStore.swift`, `Database.swift` (Migration `v19_photo_attempts`), `LocalPhoto.swift`
- Test: `ios/LegulusTests/SampleEditorPhotoTests.swift`, `DatabaseMigrationV19Tests.swift`

**Interfaces:**
- `LocalPhoto` bekommt `attempts: Int` (Default 0) und `lastAttemptAt: Date?`.
- `SampleEditorViewModel`:
  - `func addCapturedPhoto(_ data: Data) throws` — schreibt über `PhotoStorage.write(data:…)`, legt `LocalPhoto` (`pending`) an, aktualisiert `savedPhotos`, ruft `sync.kick()`. Schlägt das Einfügen in die Datenbank fehl, wird die Datei wieder entfernt und der Fehler geworfen.
  - `func deletePhoto(id: String)` — entfernt Zeile und Datei; hat das Foto eine `backendId`, wird `PendingMutation(.samplePhoto, .delete, entityId: backendId)` eingereiht.
  - `pendingPhotos`, `PendingPhoto`, `addPhoto(_:)`, `removePendingPhoto(id:)` und `persistPhotos` entfallen. Der Simulator-Rückfall (`CameraPicker`) wandelt sein `UIImage` zu JPEG-Daten (Qualität 0.92) und ruft `addCapturedPhoto`.
- Strip: Vorschaubilder über `PhotoStorage.thumbnail`, Label „Foto N von M“, Kontextmenü „Löschen“ und VoiceOver-Aktion „Löschen“, jeweils mit Rückfrage („Foto löschen?“, destruktiv). Tap-Target 44 pt.

- [ ] Failing Tests: `testAddCapturedPhoto_WritesFileAndRowImmediately` (Datei bytegleich, Zeile `pending`, ohne `saveEdits`), `testAddCapturedPhoto_InsertFailureRemovesFileAndThrows`, `testDeletePhoto_UnsyncedRemovesRowAndFileWithoutMutation`, `testDeletePhoto_SyncedEnqueuesDeleteMutation`, Migration v19 behält bestehende Zeilen mit `attempts == 0`.
- [ ] Implementieren; `SampleEditorEditTests` anpassen, wo sie `pendingPhotos` nutzen.
- [ ] Commit `feat(ios): Fotos sofort speichern und löschen können`

### Task 6: Sync – Upload je Durchlauf, WLAN-Einstellung, Löschen

**Files:**
- Create: `ios/Legulus/Core/Sync/PhotoUploadPolicy.swift`, `ios/Legulus/Core/Sync/NetworkStatus.swift`
- Modify: `ios/Legulus/Core/Sync/SyncRunner.swift`, `ios/Legulus/Core/PocketBaseClient/PhotoClient.swift`, `ios/Legulus/Core/Config/AppConfig.swift`, `ios/Legulus/Features/Settings/SettingsView.swift`, `ios/Legulus/App/AppContainer.swift`
- Test: `ios/LegulusTests/PhotoUploadPolicyTests.swift`, `SyncRunnerPhotoTests.swift`

**Interfaces:**
- `AppConfig.photosWiFiOnly: Bool` (UserDefaults, Default `false`); Einstellung „Fotos nur im WLAN hochladen“ als `Toggle` mit Fußnote „Proben werden weiter über jede Verbindung synchronisiert.“
- `protocol NetworkStatusProviding { var isOnWiFi: Bool { get } }`, Implementierung mit `NWPathMonitor` (`usesInterfaceType(.wifi)` oder `.wiredEthernet`).
- `enum PhotoUploadPolicy`:
  - `static func retryDelay(attempts: Int) -> TimeInterval` — 0, 60, 300, 900, danach 3600 Sekunden.
  - `static func isDue(_ photo: LocalPhoto, now: Date) -> Bool`
  - `static func isPermanent(_ error: Error) -> Bool` — HTTP 400–499 außer 401, 408 und 429.
  - `static func mayUpload(wifiOnly: Bool, onWiFi: Bool) -> Bool`
- `PhotoClient`: `upload(fileURL:…)` baut den Multipart-Body als temporäre Datei und nutzt `URLSession.upload(for:fromFile:)`, Timeout 300 s; `delete(id:)` (404 gilt als Erfolg).
- `SyncRunner`:
  - `runPass` ruft nach den Mutationen – und auch, wenn es keine gibt – `pushDuePhotos()`: alle `pending`/`failed`-Fotos, deren Probe eine `backendId` hat, die fällig sind, nicht als dauerhaft fehlgeschlagen vorgemerkt (Menge im Speicher, pro App-Lauf) und nach `mayUpload` erlaubt.
  - Nach erfolgreichem Upload: Existiert die lokale Zeile nicht mehr, wird sofort ein Delete für die zurückgegebene ID eingereiht.
  - `execute` behandelt `(.samplePhoto, .delete)`.
  - Fehlschlag: `attempts += 1`, `lastAttemptAt = now`, Status `failed`, Logzeile.

- [ ] Failing Tests: Policy-Tabelle (Verzögerungen, fällig/nicht fällig, dauerhaft/vorübergehend, WLAN-Matrix); Runner mit Fake-Client: Upload ohne anstehende Sample-Mutation; Probe ohne `backendId` wird übersprungen; „nur WLAN“ + kein WLAN → kein Upload, Sample-Mutation läuft trotzdem; Wechsel auf WLAN → Upload; 413 → kein zweiter Versuch im selben Lauf; 500 → zweiter Versuch erst nach der Verzögerung; während des Uploads gelöscht → Delete-Mutation für die Server-ID; Delete-Mutation ruft den Client, 404 gilt als erledigt.
- [ ] Implementieren; Commit `feat(ios): Fotos unabhängig von der Probe hochladen, WLAN-Einstellung, Löschen im Sync`

### Task 7: Abschluss PR 4

- [ ] `PHASES.md`: Phase T – PR 7 und PR 9 abhaken (beide gemergt); Phase S – Hinweis auf diesen Plan.
- [ ] `bash scripts/check-ios.sh`, Backend-Tests und Linter; Anti-Pattern-Greps.
- [ ] Prüfschritt: Test-Upload einer Datei knapp unter 50 MB gegen die lokale Test-Instanz (`localhost:8092`); im PR-Text vermerken, dass der Weg über Tunnel/Proxy damit nicht geprüft ist.
- [ ] Push, PR `feat(ios): Serienkamera, Fotos im Original, Löschen und WLAN-Einstellung`, `copilot-pr-review`. Prüfschritte für Jo am Gerät: Serie von 10 Fotos, Hoch-/Querformat, Zoom und Makro, Blitz, App während der Serie in den Hintergrund, Flugmodus und danach Sync, „nur WLAN“ im Mobilfunk, Löschen vor und nach dem Upload, EXIF der hochgeladenen Datei (Zeit, Gerät, GPS), VoiceOver und AX5 in der Kamera.

---

## PR 6

### Task 8: Foto-Import beim Nachtragen im Original

**Files:**
- Modify: `ios/Legulus/Core/Photos/PhotoStorage.swift`
- Modify: `ios/Legulus/Features/Retrospective/RetrospectiveSampleCreator.swift`
- Test: `ios/LegulusTests/PhotoImportFormatTests.swift`, bestehende `RetrospectiveEntryTests`

**Interfaces:**
- `enum PhotoImportFormat { static func jpegData(from data: Data) throws -> Data }` — JPEG-Eingabe (`CGImageSourceGetType` == `public.jpeg`) wird unverändert zurückgegeben; jedes andere Bildformat wird über `CGImageDestination` einmal nach JPEG gewandelt (`kCGImageDestinationLossyCompressionQuality` 0.92), mit den Properties des Quellbildes (EXIF, GPS, TIFF, Ausrichtung); nicht dekodierbare Daten → Fehler.
- `RetrospectiveSampleCreator.attachPhoto` nutzt `PhotoImportFormat.jpegData` und `PhotoStorage.write(data:…)`. `PhotoStorage.write(image:…)`, `resize`, `jpegQuality` und `maxLongEdge` entfallen.

- [ ] Failing Tests: `testJPEG_IsReturnedByteIdentical`; `testHEIC_BecomesJPEGWithSamePixelSizeAndMetadata` (im Test erzeugtes HEIC 4032 × 3024 mit `DateTimeOriginal`, Kameramodell, GPS und Orientierung 6 → Typ JPEG, gleiche Pixelmaße, alle vier Angaben erhalten); `testPNG_BecomesJPEG`; `testGarbage_Throws`; Nachtragen legt für ein JPEG eine bytegleiche Datei ab.
- [ ] Implementieren; `bash scripts/check-ios.sh`.
- [ ] Commit `feat(ios): Foto-Import beim Nachtragen behält Auflösung und Metadaten`; Push, PR, `copilot-pr-review`; `PHASES.md` Phase S abschließen.
