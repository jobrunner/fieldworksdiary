# Fieldworksdiary

Felderfassungs-App für entomologische Aufsammlungen (Schwerpunkt Rüsselkäfer).
Backend: PocketBase als Go-Library im Docker-Container. Frontend: native
iOS-App (SwiftUI, Offline-First, GRDB).

- **Vision & Architektur:** [`PROJECT_PLAN.md`](PROJECT_PLAN.md)
- **Konventionen für Claude Code:** [`CLAUDE.md`](CLAUDE.md)
- **Phasen-Status:** [`PHASES.md`](PHASES.md)
- **Security-Policy:** [`SECURITY.md`](SECURITY.md)
- **Environments / Staging / Prod:** [`docs/ENVIRONMENTS.md`](docs/ENVIRONMENTS.md)
- **Apple-Sign-In-Setup:** [`docs/APPLE_SIGN_IN_SETUP.md`](docs/APPLE_SIGN_IN_SETUP.md)
- **API-Spec (Custom-Routes):** [`docs/openapi.yaml`](docs/openapi.yaml)
- **Release-Checklist:** [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md)
- **Disaster Recovery:** [`docs/DISASTER_RECOVERY.md`](docs/DISASTER_RECOVERY.md)

## Dev-Setup

Tooling für Backend (Go) und iOS (SwiftUI) ist über eine Nix-Flake
gebündelt. Empfohlener Onboarding-Pfad:

1. **Xcode installieren** — App Store oder `xcodes install <version>`.
   Apple's Xcode kann nicht über Nix bereitgestellt werden (Lizenz).
2. **Command Line Tools** — `xcode-select --install` (einmalig).
3. **Nix-Shell betreten:**
   ```bash
   nix develop
   # oder automatisch via direnv (`.envrc` ist im Repo)
   direnv allow
   ```

Damit sind verfügbar: `go`, `golangci-lint`, `govulncheck`, `gofumpt`,
`swiftlint`, `swiftformat`, `xcodes`, `jq`, `zizmor`.

**Fallback ohne Nix:** `bash scripts/install-qa-tools.sh` installiert
die Tools via Homebrew bzw. `go install`.

### Claude Code Skills (Submodul)

Die Skills unter `.claude/skills/` sind Symlinks ins Submodul
`vendor/claude-skills`. Beim Klonen `--recurse-submodules` verwenden
(oder einmalig `git submodule update --init`), sonst zeigen die Symlinks ins Leere:

```bash
git clone --recurse-submodules git@github.com:jobrunner/fieldworksdiary-ng.git
# bestehender Checkout:
git submodule update --init vendor/claude-skills
# auf neueste Skills aktualisieren:
git -C vendor/claude-skills pull origin main \
  && git add vendor/claude-skills && git commit -m "chore: bump claude-skills"
```

### Commit-Konvention

[Conventional Commits](https://www.conventionalcommits.org/) sind via
`commit-msg`-Hook erzwungen. Setup einmalig:

```bash
git config core.hooksPath .githooks
```

Konvention im Detail: [`.claude/rules/COMMITS.md`](.claude/rules/COMMITS.md).

Version + Changelog laufen automatisch über
[release-please](https://github.com/googleapis/release-please)
(Konfiguration in `release-please-config.json`): jeder Push auf `main`
aktualisiert eine offene Release-PR, die `VERSION` +
`ios/project.yml`s `MARKETING_VERSION` hochzählt und `CHANGELOG.md`
befüllt. Merge dieser PR taggt den Release und legt die
GitHub-Release automatisch an — nichts davon manuell anfassen.

### Quality Checks

```bash
bash scripts/check.sh           # volle Suite (Backend + iOS + Security)
bash scripts/check-backend.sh   # nur Go
bash scripts/check-ios.sh       # nur iOS
bash scripts/check-security.sh  # gitleaks + zizmor + trivy fs
```

Bei jeder Datei-Änderung läuft zusätzlich ein **Claude-Code-PostToolUse-Hook**
inkrementell auf der geänderten Datei (`scripts/claude-post-edit.sh`).
Konfiguriert in [`.claude/settings.json`](.claude/settings.json).

CI (GitHub Actions) deckt PR-Builds, Security-Scans (`gitleaks`, `trivy fs`,
`trivy image`, `govulncheck`, `semgrep`, `zizmor` für GitHub-Actions-
Workflows selbst) und nightly-CVE-Drift ab. Siehe
`.github/workflows/`.

### Production-Backups (`pb_data/`)

```bash
bash scripts/backup-pbdata.sh                       # ins Default-Ziel ~/Backups/fieldworksdiary/
bash scripts/backup-pbdata.sh /Volumes/Backup/wapp  # an einen anderen Ort
KEEP_LAST=14 bash scripts/backup-pbdata.sh          # Retention auf 14 Backups beschränken
```

Das Skript ist write-safe (sqlite3 `.backup` ist online-konsistent —
Backup kann mit laufendem Backend laufen). Für tägliche Ausführung gibt
es eine launchd-Vorlage in
[`scripts/backup-pbdata.launchd.plist`](scripts/backup-pbdata.launchd.plist).

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
open Fieldworksdiary.xcodeproj
```

In der App unter "Einstellungen" den Backend-Endpoint setzen
(z. B. `http://localhost:8090` im Simulator, oder
`http://<host-ip>:8090` auf dem Gerät).
