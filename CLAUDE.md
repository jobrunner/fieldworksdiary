# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Konventionen und Architektur für Claude Code in diesem Repo. Siehe
`PROJECT_PLAN.md` für die ausführliche Vision und Phasenplanung — dieses
Dokument ist die Kurzfassung mit den Regeln, an die man sich beim
Implementieren halten muss.

**Phasen-Status: `PHASES.md`.** Bei jedem Statuswechsel zuerst dort
eintragen, dann weiterarbeiten — die Datei ist die Single Source of
Truth, an der eine neue Session erkennt, wo wir gerade stehen.

> Die Refactor-Initiative Sample/Locality/Placemark (R0–R8e) ist
> abgeschlossen — Abschluss-Notiz und bleibende Designentscheidungen
> in `docs/refactoring/PHASES_REFACTOR.md`. Offen bleiben nur die
> Folge-Features R9 (Export), R10 (Daten-Migration), R11 (Planning).

## Was ist das hier?

Eine Felderfassungs-App für entomologische Aufsammlungen (Schwerpunkt
Rüsselkäfer). Backend: PocketBase als Go-Library im Docker-Container.
Frontend: native iOS-App (SwiftUI), Offline-First.

**Aktueller Stand:** siehe `PHASES.md`. Inhaltliche Beschreibung der
Phasen in `PROJECT_PLAN.md` §11. Strikt inkrementell: nach Phasen-Ende
stoppen und Demo zeigen, nicht in die nächste Phase laufen.

## Projekt-Layout (geplant, siehe PROJECT_PLAN §10)

- `backend/` – Go + PocketBase. Hooks und Custom-Logik in
  `backend/internal/`. Migrations in `backend/migrations/`.
- `ios/` – SwiftUI-App. Domänen-Logik in `ios/Fieldworksdiary/Core/`,
  Features in `ios/Fieldworksdiary/Features/`.
- `docs/adr/` – Architecture Decision Records, eines pro Entscheidung.

## Drei-Ebenen-Datenmodell

```
Locality (Fundort)  ──>  Excursion (Sammeltag)  ──>  Sample (Aufsammlung, Röhrchen)
```

- Aufsammlungs-Code ist `YYMMDD/N`, wo `YYMMDD` der **Sammeltag** ist
  (mit konfigurierbarem Tagesrollover, default 5:00 morgens).
- Eine Exkursion = ein Sammeltag. Es gibt **kein** „Exkursion abschließen".
- Geographische Splits werden nur als Vorschlag im Nachhinein gemacht
  (DBSCAN-Clustering, asynchron / per Cron — niemals im Feld-Flow).
- Fundorte sind manuell kuratiert; Exkursionen werden ihnen zugeordnet
  (auto-Vorschlag bei räumlichem Match, User akzeptiert/verwirft).

Die Logik dafür sitzt im Backend (`backend/internal/codes/` und
`backend/internal/grouping/`). Der iOS-Client repliziert nur das
Mindeste für Offline-Betrieb: provisorische Code-Vergabe und
provisorische Exkursionszuordnung.

## Konventionen

### Allgemein

- **Englische Bezeichner im Code**, deutsche Strings in der UI.
- **Commits** folgen Conventional Commits (`feat(scope): …`,
  `fix(scope): …`, etc.). Hook in `.githooks/commit-msg` erzwingt das
  lokal — Konvention in @.claude/rules/COMMITS.md.
- Domänen-Begriffe (auch im Code-Kontext) sind: `Sample`, `Excursion`,
  `Locality`, `Determination`. Wir benutzen NICHT „Collection" als Modell,
  weil PocketBase „collections" für Tabellen verwendet (Namens-Konflikt).
- Datumsformate: ISO 8601 für Speicherung, `dd.MM.yyyy` für UI-Darstellung.
- Koordinaten: Dezimalgrad, 6 Nachkommastellen für Speicherung.
- Sync-Idempotenz: jedes synchronisierte Record hat `client_uuid` +
  `client_updated_at`. Konfliktauflösung: Last-Write-Wins über
  `client_updated_at`.

### Backend (Go)

- Modul-Pfad in `go.mod`: `github.com/<dein-user>/fieldworksdiary/backend`.
- Logik **niemals** im `main.go`. Dort nur Hook-Registrierung und Wiring.
- Pure Funktionen in `internal/codes/` und `internal/grouping/` mit
  Tests (das ist die Kernlogik – ohne Tests nichts mergen, > 80 % Coverage).
- Code-Sequenz pro `(user, collecting_day)` läuft über Tabelle
  `sample_sequences` mit atomic increment in einer Transaktion.
- Externe Service-Calls (`labelloc`, `mtb`) bekommen eigene Wrapper mit
  Retry, 7-Tage-Cache (`geocache`-Collection), Timeout. Niemals direkt
  aus Hooks heraus aufrufen.
- Asynchrone Anreicherung läuft in Goroutines mit Recover, damit ein
  fehlgeschlagener Service nie das Sample-Insert killt.
- **Logging**: `log/slog` mit den Key-Konventionen aus
  @.claude/rules/LOGGING.md. Kein `log.Printf`, kein `fmt.Println`. PII
  und Coordinates niemals im Klartext.

### iOS (Swift)

- Architektur: Feature-Folders, MVVM mit Combine oder Observation.
- Persistenz: GRDB. Modelle als Codable-Structs, die sowohl GRDB als
  auch das PocketBase-JSON-Schema mappen können.
- Sync-Layer: Schreibvorgänge gehen **immer** zuerst lokal in die DB,
  Sync-Queue pusht nach. Nie auf Online-Calls warten.
- Endpoint-URL kommt aus `AppConfig` (UserDefaults), darf an einer
  Stelle gesetzt werden und ist von allen Services injiziert.
- Keine Force-Unwraps in Production-Code.
- **Accessibility ist Pflicht**, nicht optional. Bei jedem UI-Refactor
  (SwiftUI und UIKit) gelten die Regeln aus
  @.claude/rules/ACCESSIBILITY-IOS.md — bei Konflikt mit Style-Vorgaben
  oder Design-Tokens gewinnt die Regel-Datei.
- **Design-System**: Features bauen nur aus Tokens (`Core/Theme/`)
  und Atoms (`Core/UI/`). Magic-Numbers, Hex-Farben und feste Font-
  Größen sind verboten — siehe @.claude/rules/DESIGN-SYSTEM.md
  (inkl. Drei-Wiederholungen-Regel und Migrations-Workflow).
- **Logging** läuft ausschließlich über `Log.<category>` aus
  `Core/Observability/Log.swift` (OSLog-basiert). `print()` ist verboten.
  Subsystem-/Category-/Privacy-Konvention: @.claude/rules/LOGGING.md.

### Tests

- Backend: `go test ./...` muss grün sein. Kernlogik
  (`codes/`, `grouping/`) braucht > 80 % Coverage.
- iOS: Unit-Tests für `Core/Sync/`, `Core/Geo/codes/`. UI-Tests optional.

## Externe Services (read-only Endpoints, gehosted auf dem Docker-Host)

- Reverse Geocoding: `https://labelloc.example.org/api/location?lat=&lon=&lang=de`
- MTB-Lookup: `https://coordstomtb.example.org/api/coordinate?lat=&lon=&id=`

Beide Wrapper liegen in `backend/internal/services/`. Antworten werden
in `geocache` (eine PocketBase-Collection) für 7 Tage gecacht. Der
`labelloc`-Response hat ein bekanntes UTF-8-Issue (`WÃ¼rzburg`) – defensiv
behandeln (re-decode versuchen, sonst Roh-Wert speichern und im Log
markieren). MTB liefert in der Regel nur DE-Bezüge — außerhalb DE bleibt
`mtb` leer (kein Fehler).

## Was der Agent NICHT von sich aus tun soll

- **Phasen aus `PROJECT_PLAN.md` überspringen oder zusammenlegen.**
  Strikt inkrementell vorgehen; nach Phase 0 stoppen und Demo zeigen.
- App-Store-Konfiguration anpacken, bevor explizit gefragt.
- FloraIncognita anbinden, bevor Phase 9 erreicht ist.
- PocketBase-Standalone-Binary verwenden (immer als Go-Library!).
- Logik vom Backend in den iOS-Client duplizieren, außer wo Offline es
  zwingend erfordert (Code-Vergabe, Sammeltag-Berechnung).

## Build & Run (Dev)

```bash
# Backend
docker compose up --build

# Backend Tests
cd backend && go test ./...

# Einzelner Go-Test
cd backend && go test ./internal/codes -run TestCollectingDay

# iOS-Projekt erzeugen (xcodegen, einmalig nötig oder nach project.yml-Änderung)
cd ios && xcodegen generate

# iOS bauen (CLI-Verifikation)
cd ios && xcodebuild -project Fieldworksdiary.xcodeproj -scheme Fieldworksdiary \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

Nach erstem Backend-Start: PocketBase-Admin unter
`http://localhost:8090/_/` einrichten. Danach in der iOS-App den
Endpoint `http://<host>:8090` setzen.

`ios/Fieldworksdiary.xcodeproj/` ist gitignored und wird aus
`ios/project.yml` regeneriert (`xcodegen generate`). Quelle für
Projekt-Änderungen ist immer `project.yml`, nicht das `.xcodeproj`.

