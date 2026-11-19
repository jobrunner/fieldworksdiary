# Sample-Ansicht: Kopieren, Stift-Icon, Datumszeile, Serienkamera, kleinere Sample-Nummer, Foto-Import im Original

Stand: 2026-11-18. Status: Entwurf, wartet auf Freigabe durch Jo.

## Anlass

Sechs Verbesserungen rund um die Sample-Ansicht (`SampleEditorView`, die Ansicht,
die nach Tap auf eine Probe erscheint). Sie kommen aus der Benutzung im
Feld: Koordinaten sollen sich in andere Apps übernehmen lassen, „Bearbeiten“
ist hinter „…“ versteckt, die Datumszeile ist bei großer Schrift schlecht
lesbar, Fotos lassen sich nicht zügig hintereinander aufnehmen und werden
verkleinert, und die Sample-Nummer nimmt zu viel Platz ein.

Jede Verbesserung bekommt einen eigenen Feature-Branch und einen eigenen PR.

## Ausgangslage im Code

- `ios/Legulus/Features/SampleEditor/SampleEditorView.swift` enthält alle
  betroffenen Stellen: Toolbar, `editableSection` (Sample-Nummer, Notizen,
  Foto-Strip), `locationRow` (`coordinateBlock`, `altitudeBlock`), `timeRow`.
- Die Toolbar hat rechts drei Einträge: „Bearbeiten“ (Text), Kamera, Stern.
  iOS 26 klappt sie vermutlich aus Platzgründen zu „…“ zusammen (nicht im
  Simulator nachgestellt).
- `timeRow` zeigt als Icon `moonSymbol` (Mondphase der Exkursion, ohne
  Astro-Daten `moon.stars`).
- Fotos: `CameraPicker` (`UIImagePickerController`) nimmt ein Bild auf und
  schließt. Bilder liegen als `UIImage` in `pendingPhotos` im Speicher, bis
  `saveEdits()` sie über `PhotoStorage.write(image:…)` schreibt. Dabei wird
  auf 2400 px lange Kante und JPEG-Qualität 0.85 heruntergerechnet, EXIF geht
  verloren.
- Upload: `SyncRunner.pushPhotos` läuft nur direkt nach dem Anlegen oder
  Ändern des Samples (ein Multipart-POST pro Foto an `sample_photos`,
  idempotent über `client_uuid`). Das Backend begrenzt `photo_file` auf
  10 MB (`tabularius/migrations/1700000012_phase14_sample_photos.go`).

## Die sechs Features

### 1 – Koordinate und Höhe per Tap kopieren

Branch `feat/sample-copy-coordinate`, von `main`.

- Koordinate und Höhe in `locationRow` werden je ein echter `Button`
  (optisch weiter wie Text). Tap kopiert in die Zwischenablage.
- Kopierter Text, unabhängig von Gebietsschema (Dezimalpunkt):
  - alle acht geographischen Anzeigeformate: Dezimalgrad mit Vorzeichen,
    6 Nachkommastellen, Komma ohne Leerzeichen: `49.123456,10.123456`
  - MGRS: ohne Leerzeichen, `32UNA6938014686`
  - UTM: ohne Leerzeichen (Jos Entscheidung)
  - Höhe: gerundete Meter ohne Leerzeichen, `276m`
- Ohne Koordinate bzw. ohne Höhe („—“, „Suche Position …“) gibt es nichts
  zu kopieren, das Element ist dann kein Button.
- Rückmeldung: kurzer sichtbarer Hinweis „Kopiert“ (ca. 1,5 s, ohne
  Layout-Sprung, Animation respektiert Reduce Motion), Haptik, und eine
  VoiceOver-Ansage („Koordinate kopiert“ / „Höhe kopiert“).
- A11y: Die Zeile ist heute ein kombiniertes Element. Künftig zwei Buttons
  mit Label („Koordinate …, MGRS“ / „Höhe 276 Meter“) und Hint „Kopiert in
  die Zwischenablage“. Genauigkeitsangaben bleiben Teil des jeweiligen
  Labels. Tap-Target mindestens 44 × 44 pt.
- Die Text-Erzeugung ist eine pure Funktion neben `PlaceDisplay.coordinate`
  mit Unit-Tests für alle zehn Formate, negative Koordinaten und die Höhe.

Nicht-Ziel: Kopieren im Bearbeiten-Formular oder in Listen.

### 2 – Stift-Icon statt „…“

Branch `feat/sample-toolbar-edit-icon`, von `main`.

- Toolbar rechts: genau ein Eintrag, Icon `pencil`, `accessibilityLabel`
  „Bearbeiten“, bestehender Hint bleibt. Aktion unverändert (`openForm`).
- Der Stern (Markieren) wandert in den Inhalt, rechts neben das
  Sample-Nummern-Feld. Labels wie heute („Probe markieren“ / „Markierung
  entfernen“), 44 × 44 pt.
- Die Kamera wandert in den Foto-Bereich unter den Notizen: Kopfzeile
  „Fotos“ mit Kamera-Button (`camera.fill`, Label „Foto aufnehmen“), immer
  sichtbar, auch ohne Fotos. Darunter der Strip, wenn Fotos vorhanden sind.
  In diesem PR öffnet der Button noch die bisherige Kamera.

### 3 – Datumszeile

Branch `feat/sample-date-row`, von `main`.

- Icon: `calendar` statt Mondphase. `moonSymbol` entfällt ersatzlos (die
  Mondphase steht weiter im Astro-Panel der Exkursion).
- Datum per `ViewThatFits`: einzeilig „Montag, 16. November 2026“, solange
  es passt. Sonst zwei Zeilen: „Montag,“ und „16. November 2026“. Darunter
  wie bisher der Uhrzeitbereich. `lineLimit(2)` und `minimumScaleFactor`
  entfallen.
- VoiceOver-Label der Zeile bleibt unverändert.

### 4 – Serienkamera, Fotos in voller Auflösung mit EXIF

Branch `feat/sample-photo-series`, gestapelt auf `feat/sample-toolbar-edit-icon`
(beide fassen den Kamera-Button an). Einziger Teil mit Backend-Änderung.

**Ziel:** Im Feld mehrere Belegfotos zügig hintereinander aufnehmen. Die
Dateien landen unverändert (volle Auflösung, JPEG, alle EXIF-Daten) auf dem
Gerät und im Backend.

**Kamera (Jos Entscheidung: eigene Kamera auf AVFoundation):**

- Vollbild-Ansicht mit Live-Vorschau, Auslöser, Zähler der Aufnahmen
  dieser Sitzung, Vorschau des letzten Bildes, „Fertig“.
- Die Kamera bleibt nach jedem Auslösen offen, es gibt keinen
  Bestätigungsschritt.
- Rückkamera. Wenn vorhanden das virtuelle Mehrfach-Kameragerät, damit
  Zoom und Nahbereich (Makro) automatisch die Linse wechseln. Pinch-Zoom,
  Tap-to-Focus, Blitz Auto/Aus.
- Hoch- und Querformat werden korrekt in die Datei geschrieben.
- Kamera-Zugriff verweigert: Hinweis mit Sprung in die Einstellungen.
- Simulator (keine Kamera): Rückfall auf den bisherigen `CameraPicker`,
  damit der Ablauf testbar bleibt.
- A11y: alle Bedienelemente mit Label, 44 × 44 pt; Ansage „Foto 3
  aufgenommen“ nach jedem Auslösen; Bedienelemente bleiben bei AX5 lesbar.

**Datei:**

- `AVCapturePhotoOutput` liefert JPEG. `fileDataRepresentation()` wird
  unverändert geschrieben: kein Neu-Kodieren, kein Verkleinern, EXIF
  bleibt vollständig.
- Die Kamera schreibt kein GPS in die EXIF-Daten. Die App ortet während
  der Kamera-Sitzung und ergänzt die tatsächliche Aufnahmeposition als
  GPS-Block (Jos Entscheidung). Ohne Fix bleibt der GPS-Block leer; die
  gespeicherte Sample-Koordinate wird nicht ersatzweise eingetragen. Das
  Auslösen wartet nie auf einen Fix.
- Auflösung: Standard-Fotoauflösung des Geräts (12 bzw. 24 MP), nicht der
  48-MP-Modus (mein Vorschlag: 48-MP-JPEGs haben 10-20 MB und sind über
  Mobilfunk kaum hochzuladen).
- `PhotoStorage` bekommt einen Schreibweg für fertige Dateidaten. Der
  bisherige `UIImage`-Weg mit Verkleinerung entfällt mit Feature 6.

**Speichern:**

- Jede Aufnahme wird sofort auf die Platte geschrieben und als
  `LocalPhoto` (`pending`) eingetragen. Der Zwischenzustand „noch nicht
  gespeichertes Foto“ (`pendingPhotos` mit `UIImage` im Speicher) entfällt
  für Kamerafotos.
- Die Originaldateien bleiben nach dem Upload auf dem Gerät, wie heute
  (mein Vorschlag). Der Foto-Strip zeigt verkleinerte Vorschauen, die aus
  der Datei erzeugt werden, statt das volle Bild zu dekodieren.

**Löschen (Jos Entscheidung: überall):**

- Der bisherige „x“-Button für ungespeicherte Fotos entfällt. Dafür lässt
  sich jedes Foto im Strip löschen, auch ein bereits hochgeladenes, mit
  Rückfrage („Foto löschen?“).
- Erreichbar ohne versteckte Geste: Kontextmenü am Vorschaubild und
  VoiceOver-Aktion „Löschen“.
- Lokal wird sofort gelöscht (Datei und Zeile). War das Foto schon
  hochgeladen, geht das Löschen offline-fähig über die Sync-Queue ans
  Backend (`DELETE` auf den `sample_photos`-Record). Ein noch nicht
  hochgeladenes Foto wird nur lokal entfernt; ein gerade laufender Upload
  darf es nicht wieder anlegen.
- Der Umsetzer prüft, ob die Delete-Rule von `sample_photos` das dem
  Besitzer erlaubt, und ergänzt sie sonst per Migration.

**Sync:**

- Backend: neue Migration hebt `sample_photos.photo_file.MaxSize` von
  10 MB auf 50 MB.
- `SyncRunner` lädt in jedem Durchlauf offene oder fehlgeschlagene Fotos
  bereits übertragener Samples hoch, nicht mehr nur direkt nach einem
  Sample-Push. Nach „Fertig“ wird der Sync angestoßen.
- Der Upload liest die Datei unverändert. Timeout (heute 60 s) wird für
  größere Dateien angehoben; Details dem Umsetzer überlassen.
- Neue Einstellung „Fotos nur im WLAN hochladen“, Standard aus (Jos
  Entscheidung): Fotos gehen über jede Verbindung, mit Schalter warten sie
  auf WLAN. Sample-Daten syncen unabhängig davon immer.
- Fehlgeschlagene Uploads werden nur geloggt, es gibt keine Anzeige am
  Foto (Jos Entscheidung). Wiederholt wird mit wachsendem Abstand statt
  in jedem 30-s-Durchlauf. Bei endgültigen Fehlern (4xx, Datei über 50 MB)
  gibt es keinen Dauer-Retry im selben App-Lauf.
- Idempotenz: Der Index auf `sample_photos.client_uuid` ist nicht
  eindeutig. Der Umsetzer prüft, ob ein wiederholter Upload wirklich kein
  Duplikat erzeugt, und sichert das sonst im Backend ab.
- Prüfschritt vor dem Merge: Test-Upload einer Datei knapp unter 50 MB
  über den Tunnel. Ob ein Proxy vor Tabularius kleinere Bodies kappt, ist
  aus dem Repo nicht ersichtlich.
- Schreiben geht wie immer zuerst lokal, der Upload blockiert nie die
  Oberfläche.

**Nicht-Ziele:** Video, Frontkamera, RAW/HEIC, 48 MP, nachträgliches
Hochrechnen alter Fotos, Download von Fotos auf andere Geräte, Aufräumen der Originale nach dem
Upload, Sync-Status-Anzeige am Foto.

**Anti-Ziel:** Ein Foto, das der Nutzer aufgenommen hat, darf nie
stillschweigend verloren gehen (App im Hintergrund, Absturz, voller
Speicher → sichtbare Fehlermeldung).

### 5 – Kleinere Schrift für die Sample-Nummer

Branch `feat/sample-code-font`, von `main`.

- Das Feld nutzt `AppFont.codeEmphasized` (Body-Größe, monospaced,
  semibold) statt `title2`. Skaliert weiter mit Dynamic Type.

### 6 – Foto-Import beim Nachtragen im Original

Branch `feat/retrospective-photo-original`, gestapelt auf
`feat/sample-photo-series` (nutzt dessen Schreibweg und das neue Limit).

**Ziel:** Mit dem hochgeladenen Bild soll man weiterarbeiten können wie
mit dem Original aus der Mediathek.

- Heute dekodiert `RetrospectiveSampleCreator.attachPhoto` die gewählte
  Datei zu `UIImage` und schreibt sie verkleinert und ohne EXIF neu.
- Künftig:
  - Ist die gewählte Datei ein JPEG, werden ihre Bytes unverändert
    gespeichert und hochgeladen.
  - Jedes andere Format (HEIC, PNG, …) wird einmal nach JPEG gewandelt:
    volle Pixelgröße, hohe Qualität (ca. 0.92), alle Metadaten (EXIF, GPS,
    TIFF, Ausrichtung) werden in die JPEG-Datei übernommen.
- Die Metadaten-Auswertung für das Sample (Aufnahmezeit, Position) bleibt
  unverändert und liest weiter die Originaldaten.
- Unit-Tests: JPEG bleibt bytegleich; HEIC wird zu JPEG mit gleicher
  Pixelgröße und erhaltenen EXIF-/GPS-Feldern.

Nicht-Ziel: Mehrfachauswahl, Import in ein bestehendes Sample.

## Ansätze

Für 1, 2, 3 und 5 gibt es je einen naheliegenden Weg im bestehenden
SwiftUI-Code; Alternativen (z.B. `.textSelection` statt Tap für 1) erfüllen
die Anforderung „Tap kopiert ein festes Format“ nicht.

Für die Kamera standen drei Wege zur Wahl:

| Weg | Vorteil | Nachteil |
|---|---|---|
| Systemkamera, öffnet sich nach jedem Bild wieder | kleinster Aufwand | ein Bestätigungs-Tap pro Bild, liefert `UIImage` ohne EXIF |
| Systemkamera mit eigenem Auslöser-Overlay | Serie ohne Bestätigung | Standard-Bedienelemente entfallen, weiter `UIImage` ohne EXIF |
| Eigene Kamera auf AVFoundation | Serie, Originaldaten mit EXIF | größter Aufwand, Bedienung und A11y selbst bauen |

Jo hat die eigene Kamera gewählt, mit JPEG in voller Auflösung und allen
EXIF-Daten. Nur dieser Weg liefert die EXIF-Daten ohne Umwege.

## Reihenfolge und PRs

| PR | Branch | Basis | Commit-Typ |
|---|---|---|---|
| 1 | `feat/sample-copy-coordinate` | `main` | `feat(ios)` |
| 2 | `feat/sample-toolbar-edit-icon` | `main` | `feat(ios)` |
| 3 | `feat/sample-date-row` | `main` | `feat(ios)` |
| 4 | `feat/sample-photo-series` | PR 2 | `feat(ios)`, `feat(tabularius)` |
| 5 | `feat/sample-code-font` | `main` | `feat(ios)` |
| 6 | `feat/retrospective-photo-original` | PR 4 | `feat(ios)` |

Die PRs 1 bis 5 ändern `SampleEditorView.swift` an verschiedenen Stellen. Kleine
Merge-Konflikte beim zweiten und dritten Merge sind möglich und werden per
Rebase gelöst. Der Eintrag in `PHASES.md` und dieses Dokument kommen mit
PR 2.

## Prüfung

- Pro PR: `bash scripts/check-ios.sh` grün, Anti-Pattern-Greps aus
  `ACCESSIBILITY-IOS.md` und `DESIGN-SYSTEM.md` über die geänderten Dateien,
  im PR-Text vermerkt, auf welchen Stufen geprüft wurde. Beim Anfassen
  werden Magic-Numbers der betroffenen View-Teile durch Tokens ersetzt.
- PR 4 zusätzlich: `go test ./...`, Unit-Tests für den neuen
  `PhotoStorage`-Schreibweg (Daten bleiben bytegleich) und für den
  Foto-Upload außerhalb eines Sample-Push.
- Die Kamera selbst lässt sich nur auf einem Gerät prüfen. Das übernimmt
  Jo; der PR-Text nennt die Prüfschritte.

## Dem Umsetzer überlassen

- Aufbau der Kamera-Klassen (Session-Controller, View, Vorschau-Layer).
- Genaue Gestaltung des „Kopiert“-Hinweises.
- Upload-Technik (Datei-Upload statt Daten im Speicher, Timeout-Wert).
- Platzierung der neuen Tests.
