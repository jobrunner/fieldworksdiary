# ADR 0003: Drei-Stage-System mit getrennten Bundle-IDs und Co-Hosting

**Datum:** 2026-05-16
**Status:** teilweise abgelöst (2026-11-10): die automatischen
Deploy-Workflows (SSH-Deploy, TestFlight-Upload) sind entfernt; CI baut
nur noch das Image (`docker-release.yml`), deployt wird manuell. Siehe
`docs/ENVIRONMENTS.md`.
**Kontext:** Pre-App-Store-Submit, Aufbau Staging-Pipeline

## Entscheidung

1. **Drei Build-Channel** statt zwei: `dev` (lokal), `staging`
   (gh:staging-Branch), `production` (gh:main-Branch). „Dev" ist nicht
   eine separate Deploy-Stage, sondern der Default-Channel für lokale
   Entwicklungs-Builds; entscheidet sich pro Build-Config.

2. **Getrennte iOS-Bundle-IDs** pro Channel — `org.fieldworksdiary.dev`,
   `…staging`, `…Fieldworksdiary`. Damit kann ein Tester Staging und
   Production parallel auf demselben Gerät installieren, eindeutige
   App-Icons und ein farbiges `EnvBadge` (siehe
   `Core/Observability/EnvBadge.swift`) verhindern Verwechslung.

3. **Backend co-hosted auf einer Docker-Maschine**, isoliert per:
   - eigene Container-Namen (`fieldworksdiary-backend-staging` vs
     `…-prod`)
   - eigene Ports (8091 staging / 8090 prod)
   - eigene Volumes (`pb_data_staging/` vs `pb_data_prod/`)
   - Image-Tags `:staging` und `:prod` aus `ghcr.io`

4. **Promotion-Flow:** `feature/* → staging → main`. `staging`-Push
   triggert Auto-Deploy ohne Approval; `main`-Push triggert die
   Pipeline, aber Deploy- und TestFlight-Step hängen an der GitHub-
   Environment `production` bzw. `production-ios` mit Required
   Reviewers.

5. **Compose-Overlays** (`docker-compose.staging.yml`,
   `docker-compose.prod.yml`) statt einer einzigen Compose-Datei mit
   Profilen. Begründet durch klare „pull image, no build"-Semantik
   in Prod/Staging und Build-Default lokal.

## Alternativen, die wir verworfen haben

- **Gleiche Bundle-ID + TestFlight-Tracks** statt getrennter IDs:
  Hätte ASC-Setup-Aufwand gespart, aber Parallel-Install ist für
  Beta-Tests zu wertvoll. Lehrgeld vermeiden, das andere Solo-Devs
  schon gezahlt haben.

- **Separater Host für Staging**: Volle Isolation, aber Mehrkosten
  und Mehrwartung. Solange Staging keine Last-Tests fährt, reicht
  Co-Hosting mit Volume- und Container-Trennung. Re-evaluate bei
  Phase ⩾ 12 wenn Performance-Tests einziehen.

- **Auto-Promote auf main**: zu riskant, weil ein versehentlich
  gemergter Hotfix sofort live ginge. Approval-Gate via GH
  Environments ist 30 s Mehraufwand und fängt Unfälle.

## Konsequenzen

- Drei Xcode-Schemes (`Fieldworksdiary`, `Fieldworksdiary-Staging`, `Fieldworksdiary-Prod`)
  und drei Build-Configs (Debug/Staging/Release) — etwas mehr Konfig
  in `ios/project.yml`, aber jede Config setzt nur 4 Variablen
  (Bundle-ID, Display-Name, APP_ENV, BACKEND_ENDPOINT_DEFAULT).

- Zwei App-Store-Connect-Einträge nötig, **aber** ein einziger
  ASC-API-Key reicht — Keys sind account-weit.

- `AppConfig` liest beim ersten Launch `BACKEND_ENDPOINT_DEFAULT` aus
  der `Info.plist` und übernimmt das. UserDefaults-Override bleibt
  möglich (für DEV-Buides oder „Beta gegen lokales Backend testen").

- Backups laufen separat pro Volume (`pb_data_staging/`,
  `pb_data_prod/`). DR-Runbook (`docs/DISASTER_RECOVERY.md`)
  beschreibt das.

## Referenzen

- Implementierung: `ios/project.yml`, `docker-compose.staging.yml`,
  `docker-compose.prod.yml`, `.github/workflows/deploy-staging.yml`,
  `.github/workflows/deploy-prod.yml`.
- Setup-Doku: `docs/ENVIRONMENTS.md`.
- Verwandte ADRs: 0002 (Auth & Owner-Scoping — gilt unverändert in
  beiden Stages).
