# Continuation Notes — Refactor-Initiative

Dieses Dokument ist ein **Start-here für eine frische
Claude-Code-Session**. Es bündelt: aktuellen Status, Workflow,
bekannte Stolperfallen, und pro offene Phase einen
ausführungsfertigen Bauplan. Nach Abschluss aller Phasen wird
es ersatzlos gelöscht (siehe Sektion „Aufräumen am Schluss").

---

## TL;DR

**Status:** R0–R7.3 + R8a sind als 15 lineare Commits über
`origin/main` (lokal noch nicht gepusht). Quelle der Wahrheit für
Phasenstatus ist `docs/refactoring/PHASES_REFACTOR.md`; die
Spec liegt unverändert in `fieldsampling-refactoring-plan.md`.

**Offen (Reihenfolge fast frei):**

- R7.4 — `samples.admin_units` als Spalte droppen
- R8b — Manual-Override-Sheet im LocalityDetailView
- R8c — Remap-Toast + FlagAmbiguous-Badge in der Localities-Liste
- R8d — AddSample-Sheet mit drei Modi + Offline-Fusion-Integration
- R8e — Map / Sample-ID-Template / Filter

Jede Phase = ein eigener Branch, ein Commit (oder wenige), dann
rebase auf `main` + ff-merge.

**Beim Start einer neuen Session:**

1. Lies diese Datei (oben → unten).
2. Lies `docs/refactoring/PHASES_REFACTOR.md` für Details-Historie.
3. Lies `fieldsampling-refactoring-plan.md` nur, wenn die Spec
   für eine konkrete Phase nachgeschlagen werden muss.
4. Wähle die nächste Phase (User-Vorgabe oder die oberste
   offene aus der Liste), eröffne den Branch, und arbeite die
   Schritte unter „Pro Phase" ab.

---

## Workflow pro Phase

```bash
git checkout -b refactor/<id>-<slug>

# … arbeiten + Tests …

git add -A
git commit -m "<scope>: <id> — <kurz>" -m "<details>"

git rebase main                            # idempotent, falls main weg ist
git checkout main
git merge --ff-only refactor/<id>-<slug>
```

**Commit-Konvention** (Conventional Commits, lokal erzwungen
über `.githooks/commit-msg`):

- Scope-Tags: `(backend)` `(ios)` `(refactor)` `(ui)` `(fusion)`
  `(placemark)` `(sync)`. Mehrere möglich.
- Body erklärt **warum**, nicht **was**. Verweise auf die
  Phase-ID (z. B. „R8b") und auf das gelöste Problem.
- Multi-Line-Bodies via HEREDOC:
  `git commit -m "$(cat <<'EOF' … EOF)"`.

**Nach jeder Phase**: `docs/refactoring/PHASES_REFACTOR.md` so
updaten, dass die Phase auf `done` springt und die nächste auf
`pending` bleibt. Tabelle pflegen, Status-Block oben kurz.

---

## Test-Commands (mit den nix-shell-Quirks)

**Backend, full sweep:**
```bash
cd backend
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  go test -count=1 ./...
```

`SDKROOT=` ist **zwingend**, sonst scheitert der Linker für
CGO-Pakete (`ld: library 'resolv' not found`). Reines `go vet
./...` braucht das nicht.

**iOS, einzelne Tests:**
```bash
env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild -project ios/Fieldworksdiary.xcodeproj \
    -scheme Fieldworksdiary \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' \
    test -only-testing:FieldworksdiaryTests/<TestSuiteName> \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**iOS, full build (vor Commit):**
```bash
env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild -project ios/Fieldworksdiary.xcodeproj \
    -scheme Fieldworksdiary -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

`env -i` blank-startet die Umgebung, ohne `env -i` collide-iert
die nix-Toolchain mit Xcode's Linker. Wenn neue Dateien zum
Projekt hinzugefügt wurden: `cd ios && xcodegen generate`
**vor** dem Build (xcodegen erkennt Dateien per Discovery).

---

## Bekannte Stolperfallen

- **`SnapshotsTests.testPrimaryButton` failt durchgehend** —
  Xcode-Renderer-Drift zwischen Versionen, nicht
  Refactor-bedingt. Bei jedem Branch ignorieren. Wird in einer
  separaten Aufräum-Initiative gelöst.
- **Hash-Algorithmus für Placemark-Dedup steht an drei Stellen**:
  `backend/internal/enrichment/placemark.go::PlacemarkDedupHash`,
  `backend/internal/api/placemark.go::manualDedupHash`,
  `backend/migrations/1700000020_phase_r7_backfill_placemarks.go::backfillDedupHash`.
  Alle drei pinned auf
  `4b7015e1caea6410c452841f331eb3855010ee52d13d4c4573ca18f461c81fa7`
  über `…_LockedConstant`-Tests. Bei einem Touch an einer Stelle
  → alle drei nachziehen + alle drei Tests laufen lassen.
- **PocketBase-Test-Setup**: in `internal/api/*_test.go` **kein**
  `t.Cleanup(app.Cleanup)` aufrufen — racet sich mit der
  Logger-Hook-Shutdown in 10-Minuten-Hänger. Stattdessen
  `app.ResetEventCalls()` nach dem Setup, damit der
  `ExpectedEvents`-Vergleich nur die Test-Aktionen sieht (siehe
  `internal/api/placemark_test.go` als Vorlage).
- **Lokale Branches sind noch nicht gepusht.** `origin/main` ist
  der Stand vor R0. Wenn die Session ein "ich brauche
  origin"-Szenario hat, erst `git status` checken — der User
  pusht selbst, wir nicht.
- **8 alte Refactor-Branches** (`refactor/R2-…` bis
  `refactor/R8a-…`) liegen lokal rum, sind alle in main
  gemerged. Der User hat ihre Aufräumung bisher offen gelassen
  → nicht ungefragt löschen.

---

## Pro offene Phase

### R7.4 — `samples.admin_units` droppen

**Trigger**: Spec §6.1 verlangt eine Woche Staging-Beobachtung
nach R7.3. Wenn der User „R7.4 go" sagt, ist die Beobachtung
durch.

**Branch**: `refactor/R7.4-drop-admin-units`

**Files**:
- `backend/migrations/1700000021_phase_r7_drop_samples_admin_units.go`
  — neue Migration.

**Inhalt**:
- Up: `ALTER TABLE samples DROP COLUMN admin_units` via
  PocketBase-DAO (Field-ID-basiert, siehe wie es in
  `1700000017_phase_r3_samples_extended.go` Renames macht).
- Down: Spalte wieder anlegen als JSON-Feld (max 2 MiB), default
  empty. Backfill aus `placemarks` ist nicht möglich — Down ist
  „bester Effort, leerer Snapshot".
- **`excursions/fieldtrips.admin_units` bleibt unangetastet**
  (Spec NEW-2: Snapshot auf Fieldtrip behalten für
  Filter-Performance).
- Vor dem Drop: check ob R7.3-Migration durchgelaufen ist —
  pragmatischer Pfad ist „R7.3 hat ihren Lauf hinter sich, weil
  sie auf jeder Boot-Migration einmal lief; wenn der Server
  jetzt R7.4 sieht, muss R7.3 abgehakt sein".

**Tests**:
- 1 Migration-Test in
  `backend/migrations/1700000021_…_test.go`: nach Migrationen
  hat `samples` keine `admin_units`-Spalte mehr
  (via `FindCollectionByNameOrId("samples").Schema.GetFieldByName("admin_units") == nil`).

**Code-Folge-Adjustments** (im selben Commit):
- `backend/internal/api/labels.go::sampleToLabel` liest
  `s.GetString("admin_units")` und propagated dann auf
  `ft.GetString("admin_units")`. Erste Zeile droppen, nur noch
  fieldtrip-side lesen.
- `backend/internal/enrichment/enrichment.go::maybePropagateToFieldtrip`
  liest `sample.GetString("admin_units")` zur Propagation. Den
  Pfad droppen — die Propagation wird in R3-Spec eh nicht mehr
  gebraucht, weil Placemark via Locality läuft.
- Tests (`labels_test.go`, `enrichment_test.go`): `admin_units`
  auf Samples nicht mehr setzen; bestehende Test-Fixtures
  rewrite oder skip.

**Akzeptanzkriterium**:
- `go test ./...` grün.
- Spaltenscan: `rg '"admin_units"' backend/internal/` nur noch
  in fieldtrip-Kontext.
- Eine fresh-erstellte Sample-Row hat keine `admin_units`-
  Spalte mehr in der DB.

---

### R8b — Manual-Override-Sheet

**Branch**: `refactor/R8b-placemark-override`

**Files**:
- `ios/Fieldworksdiary/Features/Localities/PlacemarkEditSheet.swift`
  (neu) — Form mit den 8 Placemark-Feldern (country required
  ISO-2, rest optional). Save → PATCH; Reset → DELETE override.
- `ios/Fieldworksdiary/Core/PocketBaseClient/PlacemarkClient.swift`
  — zwei neue Methoden:
  - `setManual(localityID, fields)` → PATCH
    `/api/localities/:id/placemark`
  - `clearOverride(localityID)` → DELETE
    `/api/localities/:id/placemark/override`
- `ios/Fieldworksdiary/Features/Localities/LocalityDetailView.swift`
  — „Bearbeiten"-Button oder ein zweites Edit-Icon in der
  Adresse-Sektion öffnet das Sheet. Reset-Button nur sichtbar
  wenn `pm.geocodingSource == "manual"`.

**Wire-Body PATCH** (siehe `backend/internal/api/placemark.go`
für die Server-Erwartung):
```json
{
  "country": "DE",           // required, ISO-2, uppercase
  "administrative_area": "Bayern",
  "sub_administrative_area": "Unterfranken",
  "locality": "Würzburg",
  "sub_locality": "",
  "postal_code": "97070",
  "name": "Sanderring",
  "thoroughfare": ""
}
```

Response ist ein vollständiges `Placemark`-Objekt — direkt in
den `LocalPlacemarkStore.upsert(…)` schieben.

**Akzeptanzkriterium**:
- Detail-View hat Bearbeiten-/Reset-Buttons.
- PATCH-Roundtrip aktualisiert die Anzeige (manueller Badge
  taucht auf).
- DELETE-Roundtrip lässt den Auto-Geocode-Hook beim nächsten
  Save wieder greifen (Locality.placemark wird auf der
  Server-Seite kurzzeitig leer und füllt sich neu).

**Tests**:
- Falls möglich, ein UI-Test für die Sheet-Mechanik. Sonst
  ein Stub-Test für `PlacemarkClient.setManual` gegen einen
  httptest-Server (siehe `RemapEventClient`-Pattern für die
  Authentifizierungsstruktur).

---

### R8c — Remap-Toast + FlagAmbiguous-Badge

**Branch**: `refactor/R8c-remap-toast`

**Files**:
- `ios/Fieldworksdiary/Features/Localities/LocalitiesListView.swift`
  — Row-Renderer um Badge „⚠ möglicherweise doppelt" erweitern,
  wenn `local.needsHumanReview == true`. Eigene
  „Review-pending"-Section am Anfang der Liste, dann die
  normalen Localities.
- `ios/Fieldworksdiary/Core/Persistence/LocalLocality.swift` —
  `needs_human_review` als Spalte hinzufügen
  (Backend-Migration 19 hat sie schon; GRDB-Schema-Migration
  v12 nötig, falls die lokale DB sie noch nicht hat). Properties
  + CodingKeys.
- `ios/Fieldworksdiary/Core/Models/Locality.swift` — Wire-Field
  decoden.
- `ios/Fieldworksdiary/App/AppContainer.swift` oder ein neuer
  `Core/UI/RemapToastView.swift` — beobachte
  `Notification.localityRemapApplied`, zeige einen dezenten
  In-App-Toast („3 Samples wurden in 'Am Wasser' übernommen.").
  Format: `userInfo["movedCount"]` für die Zahl,
  `event.newLocalityID` zum Auflösen des Locality-Namens via
  `LocalLocalityStore.fetchById`.

**Akzeptanzkriterium**:
- Wenn der Backend-Fusion-Hook eine Locality als ambiguous
  flaggt, taucht sie im iOS in der Review-Section auf.
- Wenn der Backend-Hook eine Locality merged, sieht der User
  beim nächsten Hydrator-Pull einen Toast.

**Tests**:
- Ein Snapshot-Test für die Review-Badge-Variante der Row
  (Default-Variante existiert; neue Variante mit
  `needsHumanReview=true`).

---

### R8d — AddSample-Sheet + Offline-Fusion-Integration

**Branch**: `refactor/R8d-addsample-fusion`

Dies ist die größte offene Phase. Empfehlung: vor dem Start mit
dem User abklären, ob er das in einem PR oder gesplittet
möchte.

**Files**:
- `ios/Fieldworksdiary/Features/AddSample/AddSampleSheet.swift`
  — Mode-Picker („Jetzt im Feld" / „Nachträglich" / „Geplant"
  → letzteres `R11`, also disabled).
- `ios/Fieldworksdiary/Features/SampleEditor/SampleEditorViewModel.swift`
  — `save()`-Pfad wird erweitert: nach erfolgreichem
  `LocalSample`-Create, **wenn `locationSource == .locationService`**:
  1. Hole lokale Localities via
     `LocalLocalityStore.observeAll()`-Snapshot.
  2. Mappe auf `LocalityFusion.Candidate{id, latitude, longitude}`.
  3. Rufe `LocalityFusion.offlineFuseLocality(sampleLat,
     sampleLon, candidates)`.
  4. Wenn Treffer → `LocalSample.locality = match.id`. Wenn
     kein Treffer → erzeuge eine neue lokale Locality (UUID,
     `locationSource = .locationService`, coords vom Sample),
     `LocalSample.locality = newLocal.id`.
  5. Wenn neu erzeugt: Outbox-Mutation `.locality/.create`
     enqueuen (`PendingMutationsStore.enqueue(…)`); SyncRunner
     dispatcht das künftig (siehe R5b — heute nur
     `.sample/.create` wired).
- `ios/Fieldworksdiary/Core/Sync/SyncRunner.swift` — `execute(_:)`
  Dispatch-Switch um `.locality/.create` erweitern. Handler:
  Read `LocalLocality` via `entity_id`, ruft
  `LocalityClient.create(…)`, schreibt `localLocality.id =
  created.id` (backendID), nachladen + UI-Refresh.
- `ios/Fieldworksdiary/Core/PocketBaseClient/LocalityClient.swift`
  — **dringend!** `LocalityInput` benutzt heute noch
  `centroid_lat/lon/radius_m` als JSON-Schlüssel. Das ist
  ein offener R3-Bug. Auf `latitude/longitude/radius_m/
  location_source/version/client_uuid/client_updated_at`
  umstellen.

**Akzeptanzkriterium**:
- Probe wird offline angelegt → lokales `LocalLocality` taucht
  auf (Fusion oder neu).
- Bei Netz-Wiederkehr: SyncRunner pushed Locality + Sample,
  Server-Fusion-Hook (R6.1) räumt ggf. via Remap-Event auf.

**Tests**:
- Integration-Test in `SyncRunnerTests`: Sample-Create löst
  Locality-Mutation aus.
- Unit-Test des Fusion-Branches im VM (Mock-Localities,
  Sample, prüfen welches `locality.id` gesetzt wird).

**Stolperfalle**: das ist viel UI + Sync-Verdrahtung. Plane
mindestens 2 Sub-Commits ein:
1. LocalityClient-Wire-Fix + LocalityCreate-Outbox-Dispatch
   (Backend-side ist schon ready).
2. AddSample-VM + Sheet.

---

### R8e — Map / Sample-ID-Template / Filter

**Branch**: `refactor/R8e-ui-finishing`

Drei UI-Stränge, alle unabhängig:

1. **Map-View** (`Features/Localities/LocalitiesMapView.swift`
   existiert schon) erweitern um Cluster-Pins. Locality als
   Anker, Sample-Pins als Sekundärlayer. Cluster-Bibliothek:
   nichts neues einführen — MapKit hat seit iOS 17 native
   Cluster-Annotations.
2. **Sample-ID-Template-Editor**: in
   `Features/Settings/SettingsScreen.swift` (existiert) einen
   Eintrag „Sample-ID-Format" mit Template-String-Editor.
   Default `<YY><MM><DD>/<seq>`, alternative Templates auswählbar.
   `Core/Geo/Codes/` hat die Format-Funktion — die wird
   parametrisiert.
3. **Filter-Erweiterungen**:
   `Features/Fieldtrips/FieldtripsFilter.swift` hat schon
   date/seasonal/country. Hinzu: hat-Notes (Bool),
   hat-Koordinate (Bool), Fieldtrip-ID (string match).
   Sheet entsprechend anpassen.

**Akzeptanzkriterium**:
- Map zeigt Cluster bei Zoom-out, einzelne Pins bei Zoom-in.
- Template-Editor speichert in UserDefaults; nächste Sample-
  Anlage verwendet das Template.
- Erweiterte Filter funktionieren auf Liste + Karte.

**Tests**:
- `FieldtripsFilterTests` um die zwei neuen Booleans
  erweitern.
- Optional: Snapshot-Test für die Cluster-Variante.

---

## Aufräumen am Schluss

Nach Abschluss aller offenen Phasen (R7.4 + R8b–e):

1. **Doc-Aufräumung**:
   - `docs/refactoring/CONTINUATION.md` (dieses File) löschen.
   - `docs/refactoring/PHASES_REFACTOR.md` archivieren oder
     auf eine Schluss-Sektion „Initiative abgeschlossen
     <Datum>" reduzieren.
   - `fieldsampling-refactoring-plan.md` aus dem Repo-Root
     entfernen (war Eingangs-Spec, jetzt erfüllt).
2. **Branch-Aufräumung** (vom User abnicken lassen):
   ```bash
   git branch | grep refactor/ | xargs git branch -D
   ```
3. **`origin/main` synchen**:
   ```bash
   git push origin main
   ```
   Erst nach explizitem User-Go.

---

## Sicherheitsnetz / Eskalation

Wenn die nächste Session in eine Sackgasse läuft (Test-Setup
broken, unklare Spec-Stelle, etc.):

- **Backend-Test-Setup-Probleme**: schau in
  `internal/api/placemark_test.go` — dort ist das einzig
  funktionierende Muster für ApiScenario-basierte Tests mit
  `ResetEventCalls`.
- **iOS-Test-Setup-Probleme**: `LocalLocalityStoreRemapTests`
  oder `PendingMutationsStoreTests` als Vorlage für
  in-memory-GRDB-Tests; `ParseConflictVersionTests` als
  Vorlage für pure-function-Tests.
- **Spec-Ambiguität**: zurück zu `fieldsampling-refactoring-plan.md`
  und Gap-Analyse (`docs/refactoring/gap-analysis.md`).

Wenn keine Information ausreicht, **frag den User explicit
nach** statt zu raten — der hat den fachlichen Kontext, den
diese Refactor-Dokus nicht abdecken.
