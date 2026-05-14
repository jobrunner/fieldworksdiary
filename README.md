# Weevilapp

Felderfassungs-App für entomologische Aufsammlungen (Schwerpunkt Rüsselkäfer).
Backend: PocketBase als Go-Library im Docker-Container. Frontend: native
iOS-App (SwiftUI, Offline-First, GRDB).

- **Vision & Architektur:** [`PROJECT_PLAN.md`](PROJECT_PLAN.md)
- **Konventionen für Claude Code:** [`CLAUDE.md`](CLAUDE.md)
- **Phasen-Status:** [`PHASES.md`](PHASES.md)

## Quickstart

### Backend

```bash
docker compose up --build
```

Erster Start: PocketBase-Admin unter `http://localhost:8090/_/`
einrichten (Account erstellen).

Tests:

```bash
cd backend && go test ./...
```

### iOS

Xcode-Projekt wird über [xcodegen](https://github.com/yonaskolb/XcodeGen)
erzeugt:

```bash
brew install xcodegen   # einmalig
cd ios && xcodegen generate
open Weevilapp.xcodeproj
```

In der App unter "Einstellungen" den Backend-Endpoint setzen
(z. B. `http://localhost:8090` im Simulator, oder
`http://<host-ip>:8090` auf dem Gerät).
