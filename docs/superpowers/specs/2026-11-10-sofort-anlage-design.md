# Sofort-Anlage, Hintergrund-Ortung und Feature-Flags — Design

Stand: 2026-11-10 · Branch `feat/sofort-anlage` (Haupt-Checkout, keine Worktrees)

## Warum

Im Feld kostet jeder Tap. Heute öffnet „Sample anlegen“ ein Sheet mit „Schließen“, und das Sample
existiert erst nach „Probe anlegen“, wenn ein GPS-Fix da ist. Die ID steht aber meist schon auf dem
Röhrchen, bevor man tippt. Ziel: Tippen auf „+“ legt das Sample sofort an, der Editor verhält sich wie
bei „Letzte Probe“, Zurück speichert.

Später sollen Hinweise bei geschlossener App kommen (z. B. „du verlässt ein FFH-Gebiet, neues Röhrchen
anlegen“). Dafür braucht die App jetzt schon die Ortungsberechtigung „Immer“ und Feature-Flags für
experimentelle Funktionen.

## Ziele

1. „Sample anlegen“ auf dem Homescreen legt das Sample sofort lokal an (ID-Vorschlag, Zeitfenster,
   Zeitzone, Sammeltag wie Phase Z) und pusht den Editor in den Navigation-Stack (kein Sheet,
   kein „Schließen“, kein „Probe anlegen“).
2. Der Editor speichert beim Zurück und wenn die App in den Hintergrund geht — für neue und bestehende
   Samples gleich. „Sichern“ und „Änderungen verwerfen?“ entfallen.
3. Validierung beim Zurück:
   - **Neues Sample mit leerer ID** (Format „–“): Nachfrage „Die Sample-ID darf nicht leer sein und
     muss eindeutig sein.“ mit Eingabe oder „Abbrechen“. Abbrechen löscht das ganze Sample (Fotos,
     Bestimmungen, Features) lokal und, falls schon synchronisiert, auf dem Server.
   - **Doppelte ID** (neu oder bestehend): „Diese Sample-ID ist bereits vergeben.“ mit „Korrigieren“
     oder „Bisherige ID behalten“. Alle anderen Änderungen werden trotzdem gespeichert.
   - Bei bestehenden Samples wird keine ID erzwungen (Altdaten dürfen leer bleiben).
4. Sync so früh wie möglich: das neue Sample geht sofort in die Outbox, auch bei offenem Editor.
   Folgeänderungen laufen als Update.
5. Koordinate: Das Sample entsteht oft vor dem Fix. Die Ortung läuft weiter — auch nach dem Verlassen
   des Editors und bei geschlossener App —, bis ein brauchbarer Fix da ist, höchstens 5 Minuten pro
   Sample. Der Fix wird ans Sample geschrieben (wie eine Koordinatenkorrektur: Ortus/Höhe/Zeitzone
   folgen). Mehrere schnell angelegte Samples bekommen je ihren Fix. Ohne „Immer“-Berechtigung nur im
   Vordergrund; beim Zurückkehren in den Vordergrund werden Samples ohne Koordinate, deren 5 Minuten
   noch nicht abgelaufen sind, weiter geortet.
6. Ortungsberechtigung „Immer“: nach „Beim Verwenden“ zusätzlich anfragen; Background-Mode `location`.
   Dauerhafte Überwachung (Geofencing, FFH-Hinweise) ist **nicht** Teil dieser Phase.
7. Feature-Flags über Flipt: offizieller Client `flipt-client-swift` (SPM, Version 1.5.5),
   Server `https://ff.fieldworksdiary.org` (Flipt v2, Snapshot im Namespace `default` ohne
   Anmeldung abrufbar), Environment und Namespace `default`, Entity-ID = PocketBase-User-ID,
   Kontext `platform=ios`, `app_version`. Dünne Schicht `FeatureFlags.isEnabled(_:)`: ohne Netz
   oder vor dem ersten Abruf `false`. URL in `AppConfig` (Default `https://ff.fieldworksdiary.org`).
   Debug-Ansicht in den Einstellungen (nur Debug-Build) listet die geladenen Flags. Noch kein
   produktives Flag.

## Nicht-Ziele

- Geofencing, FFH-Hinweise, Benachrichtigungen.
- Änderungen am Backend.
- Manuelles Nachtragen von Samples (eigener Modus bleibt, wie er ist).

## Entscheidungen von Claude (von Jo freigegeben im Chat)

- Ortungs-Limit 5 Minuten pro Sample; „brauchbarer Fix“ = gleiche Genauigkeitsschwelle wie heute im
  Editor.
- Flipt-Client 1.5.5 statt 1.6.0 (1.6.0 erst am 2026-11-09 erschienen).
- Speichern auch beim Wechsel in den Hintergrund.

## Bestehender Code (Einstiegspunkte)

`Features/Home/HomeView.swift` (Sheet `AddSampleSheet`, NavigationLink „Letzte Probe“),
`Features/SampleEditor/SampleEditorView.swift` / `SampleEditorViewModel.swift` (`save()`, `saveEdits()`,
`saveButton`, „Sichern“, Discard-Dialog, `startGPS`), `Core/Location/LocationProvider.swift`,
`Core/Persistence/LocalSampleStore.swift` (`createLocal`, `updateCoordinate`, `saveEdits`),
`Core/Persistence/PendingMutation.swift` (`op .delete`), `Core/Sync/SyncRunner.swift`,
`Core/Config/AppConfig.swift`, `Features/Settings/SettingsView.swift`, `ios/project.yml`,
`ios/Fieldworksdiary/Info.plist` + `Info.debug.plist`.
