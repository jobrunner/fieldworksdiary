# ADR 0006: Bump auf Go 1.25 und transitive `x/*`-Module

**Datum:** 2026-05-15
**Status:** akzeptiert
**Kontext:** Pre-App-Store-Submit, CVE-Bereinigung; `govulncheck` und
Trivy hatten 12 CVEs gemeldet.

## Entscheidung

1. **Go-Version**: `backend/go.mod` deklariert `go 1.25.0`,
   Docker-Builder verwendet `golang:1.25-alpine`. Vorher: `go 1.24`.

2. **Direkter Pin auf `golang.org/x/crypto v0.51.0`** und transitive
   Co-Bumps (`x/net v0.54.0`, `x/image v0.40.0`,
   `x/oauth2 v0.36.0`, `google.golang.org/protobuf v1.36.11`,
   `google.golang.org/grpc v1.81.1`,
   `github.com/golang-jwt/jwt/v4 v4.5.2`, plus PocketBase auf v0.22.14).

3. **Gate in Pipeline**: `govulncheck` läuft als nightly + auf jedem
   Push; Trivy-Image-Scan und Trivy-FS-Scan blockieren PRs auf
   HIGH/CRITICAL-Findings mit `--ignore-unfixed`.

## Begründung — Reihenfolge der Treiber

1. `govulncheck` meldet 10 erreichbare CVEs in
   `golang.org/x/{net,image,crypto}` und in der PocketBase-Version
   v0.22.0.
2. Bump aller vier Module zu `@latest`. Side-effect: `x/crypto v0.51.0`
   verlangt `go 1.25.0` — `go get` schiebt den `go`-Directive
   automatisch hoch.
3. **Trivy** zeigt zusätzlich CVE-2025-22868 (`oauth2`) und
   CVE-2026-33186 (`grpc/authz`-bypass). Beide sind nicht
   reachability-relevant nach Go-Vuln-DB, aber im SBOM trotzdem
   sichtbar — also auch gebumpt.
4. Docker-Image-Base auf `golang:1.25-alpine` hochgezogen, weil
   `go.mod` jetzt `go 1.25.0` verlangt.

## Alternativen, die wir verworfen haben

- **`replace`-Direktiven** statt direkter `go get`: hätte uns die
  Go-Version-Anhebung erspart, aber den Dependency-Graphen
  bereits gegen PocketBase v0.22.0 gepinnt. Da PocketBase ohnehin
  auf v0.22.14 musste, war ein sauberer `go get` der ehrlichere Weg.

- **Selektives Ignore via `.govulncheck.yaml`-Suppression**: für
  Calls, die in Tests reachable sind aber nicht in Prod. War nicht
  nötig — alle gemeldeten CVEs sind echte Prod-Pfade (PB-Internals
  ziehen `html.Parse`, `oauth2/jws` etc.).

## Konsequenzen

- Solange PocketBase auf `v0.22.x` bleibt, sind weitere x/*-Bumps
  möglicherweise begrenzt durch PB's eigene Constraints. Re-evaluate,
  wenn PocketBase v0.23+ verfügbar ist.

- Lokale Dev-Shell läuft `go_1_25` aus nixpkgs. Wer eine andere
  Go-Version via `asdf` o. ä. nutzt, sollte mindestens 1.25 haben.

- `go test ./...` und alle Hooks laufen weiter; einziger Wackler war
  ein cgo-Build-Issue mit `-lresolv` in der Nix-Shell, gelöst über
  `env -i`-Sandbox für `xcodebuild`. Reine `go build` außerhalb
  Nix-Shell und im Docker-Build funktionieren beide.

- Trivy ist ab jetzt Pflicht-Gate vor jedem Prod-Deploy (im
  `deploy-prod.yml`-Workflow). govulncheck bleibt zusätzlich, weil
  es Code-Path-aware ist und Reachability-Information liefert, die
  Trivy nicht hat.

## Referenzen

- Implementierung: `backend/go.mod`, `backend/Dockerfile`,
  `flake.nix` (`go_1_25`).
- Gate: `.github/workflows/security.yml` (govulncheck + trivy-fs +
  trivy-image), `.github/workflows/deploy-prod.yml` (trivy-Gate).
- Security-Policy: `SECURITY.md`.
