# Security Policy

Diese Datei beschreibt, wie Sicherheitsprobleme in Fieldworksdiary gemeldet
werden und welche Versionen unterstützt sind. GitHub greift den Inhalt
im **Security**-Tab des Repositories auf.

## Supported Versions

| Version | Sicherheits-Updates |
|---------|---------------------|
| `main`  | ✓ — alles, was im aktuellen Phasenkopf liegt (siehe `PHASES.md`) |
| Last released tag (`vX.Y.Z`) | ✓ — Patch-Releases auf dieser Linie, solange keine neue Minor ausstehend ist |
| Ältere Tags | ✗ — bitte aktualisieren |

Solange das Projekt vor `v1.0.0` ist (`v0.x`), gibt es keine
Backports-Garantie für vergangene `v0.x`-Versionen — Fixes landen
immer auf `main` und den nächsten Tag.

## Reporting a Vulnerability

**Bitte keine öffentlichen GitHub-Issues für Sicherheits-Themen.**
Stattdessen:

1. **GitHub Security Advisories** (bevorzugt): über
   `Security → Advisories → Report a vulnerability` im Repo.
   Funktioniert auch ohne dass Issues für dich sichtbar sind.
2. **Per E-Mail**: `jo@brunner.io` mit Betreff
   `[fieldworksdiary-security]`. PGP-Key auf Anfrage.

Worauf du zählen kannst:
- Empfangsbestätigung **innerhalb 72 Stunden**.
- Erste Einschätzung (Severity, Impact) **innerhalb 7 Tage**.
- Bei berechtigtem Befund: Fix + koordinierte Disclosure, normalerweise
  innerhalb 30 Tage. Bei systemischen Risiken (Auth-Bypass,
  Privilege-Escalation, Daten-Leak über Owner-Scoping) priorisiert.

## Threat-Model (Kurzfassung)

Die App speichert **personen­bezogene Standortdaten** (Sammelorte mit
6-Dezimal-Präzision) und **Auth-Material** (PocketBase-JWT-Token im iOS-
Keychain, optional Apple-Sign-in-Identity-Tokens). Volle Datenfluss-
Analyse: `docs/PRIVACY-DATA-FLOW.md` (TODO, Phase ⩾ 12).

### Assets

| Asset | Sensitivität | Speicherort |
|---|---|---|
| User-Account (E-Mail, Password-Hash) | hoch | PocketBase `users` (bcrypt) |
| Apple-Sign-in Identity-Token | mittel | nicht persistiert, nur als Austausch-Material gegen PB-JWT |
| PB-JWT (Access-Token) | hoch | iOS Keychain, `kSecAttrAccessibleAfterFirstUnlock` |
| Sample-Records (lat/lon, Determinations) | hoch (PII) | PB-SQLite (`backend/pb_data/data.db`) |
| Storage (Permit-PDFs, Labels) | mittel | PB-Filesystem (`backend/pb_data/storage/`) |
| labelloc-/MTB-Cache (lat/lon → Ortsname) | niedrig | PB-`geocache`, 7-Tage-TTL |

### Vertrauensgrenzen

```
[iOS-Client] ──HTTPS──> [PocketBase /api/*] ──> [SQLite]
                                       └──> [labelloc/MTB] (read-only, externe Server)
```

- **iOS ↔ Backend**: TLS Pflicht in Production (lokales Dev über
  `NSAllowsLocalNetworking` ausgenommen). PB-JWT in jedem Request.
- **Backend ↔ Self-Hosted-Services**: HTTPS, keine Auth nötig (read-only-
  Lookups), 7-Tage-Cache vor Re-Fetch.
- **Backend ↔ SQLite**: Single-Process, kein Netz-Zugriff. Admin-UI
  unter `/_/` ist **separat geschützt** und sollte über VPN/Wireguard
  nicht von außen erreichbar sein.

### Owner-Scoping

PocketBase-Collection-Rules erzwingen `owner = @request.auth.id` auf
allen relevanten Tables (`samples`, `excursions`, `localities`,
`determinations`). Ein authentifizierter User sieht nur eigene Daten;
das Backend prüft das auf jedem Read/Write. Details: `docs/adr/0002-auth-and-owner-scoping.md`.

### Was außerhalb des Threat-Models liegt

- **Physischer Zugriff aufs iPhone**: wenn das Gerät entsperrt ist,
  ist alles offen. Keychain-Items mit `AfterFirstUnlock` sind nach
  Boot+PIN für lokale Apps lesbar.
- **Kompromittierter Backend-Host**: wer Root auf der Docker-Maschine hat,
  hat alle Daten. Mitigation: regelmäßiges Backup (`scripts/backup-pbdata.sh`),
  Offsite-Kopie.
- **MITM gegen labelloc/MTB**: Auswirkung wäre falsche Reverse-Geo-
  Daten, kein Daten-Leak. Akzeptiert.

## Defense in Depth

| Lager | Maßnahme |
|---|---|
| Dependency-Scanning | `govulncheck` + `trivy fs` + `trivy image` in CI, täglich nightly |
| Secrets-Scanning | `gitleaks` auf jedem Push + History |
| SAST | `golangci-lint` mit `gosec`-Sublinter |
| SBOM | `cyclonedx-gomod` als Artefakt pro Run |
| License-Compliance | `go-licenses check` |
| Code-Review | Conventional Commits + Branch-Protection auf `main` (TODO) |
| Crash-Reports | MetricKit (iOS) — sichtbar im Xcode-Organizer |

## Disclosure-Hall-of-Fame

Wer eine valide Schwachstelle meldet, wird hier auf Wunsch namentlich
genannt. Aktuell: niemand.
