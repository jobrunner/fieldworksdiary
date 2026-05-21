# Environments — Dev / Staging / Production

Drei Build-/Deploy-Stages. Die Tabelle ist die kurze Wahrheit, der Rest
des Dokuments füllt die Details.

| Stage | Branch | Bundle-ID (iOS) | Backend-Host | Port | Volume | TestFlight-Track |
|---|---|---|---|---|---|---|
| **Dev** | beliebig (lokal) | `org.fieldworksdiary.dev` | localhost | 8090 | `./backend/pb_data/` | — |
| **Staging** | `staging` | `org.fieldworksdiary.staging` | gleiche Docker-Maschine | 8091 | `./pb_data_staging/` | Internal Beta |
| **Production** | `main` | `org.fieldworksdiary.prod` | gleiche Docker-Maschine | 8090 | `./pb_data_prod/` | External / App Store |

Staging und Production laufen **isoliert** in eigenen Docker-Containern
(`fieldworksdiary-backend-staging` vs `fieldworksdiary-backend-prod`) mit eigenen
SQLite-Volumes. Ein Crash der Staging-Datenbank kann Prod nicht treffen.

## Branch-Flow

```
feature/* ──PR──> staging ──auto─────────> Staging-Deploy + Staging-TestFlight
                     │
                     └──PR (review!)──> main ──manual approval──> Prod-Deploy + Prod-TestFlight
```

- Auf `staging` darf gepusht werden, ohne Review (Solo-Dev). Jeder
  Push triggert `deploy-staging.yml` → Backend-Image-Build,
  Container-Restart auf Port 8091, TestFlight-Beta-Upload.
- Auf `main` löst der Push den Workflow aus, aber der eigentliche
  Deploy-Step ist an die GitHub-Environment **`production`** gebunden
  (Settings → Environments → Required Reviewers).
- `iOS-Release-Build` läuft ebenfalls über die Environment
  `production-ios` — ein zweiter Approval-Punkt für den TestFlight-
  Upload.

## Compose-Overlays

Drei Compose-Files, kombiniert per `-f`:

```bash
# Lokal (Build aus Source):
docker compose up -d

# Staging (Image aus ghcr.io):
docker compose -f docker-compose.yml -f docker-compose.staging.yml pull
docker compose -f docker-compose.yml -f docker-compose.staging.yml up -d --no-build

# Production:
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
```

Das Default-`BACKEND_IMAGE` zeigt auf `ghcr.io/jbrunner/fieldworksdiary:staging`
bzw. `:prod`. Override per ENV ist möglich:

```bash
BACKEND_IMAGE=ghcr.io/.../fieldworksdiary:staging-abc1234 \
  docker compose -f docker-compose.yml -f docker-compose.staging.yml up -d --no-build
```

## iOS-Schemes

`ios/project.yml` definiert drei Configs (Debug, Staging, Release) und
drei Schemes:

| Scheme | Config | Wofür |
|---|---|---|
| `Fieldworksdiary` | Debug | Lokale Entwicklung, Tests, Simulator |
| `Fieldworksdiary-Staging` | Staging | TestFlight-Beta-Builds, CI auf `staging` |
| `Fieldworksdiary-Prod` | Release | App-Store-Submits, CI auf `main` |

Jede Config bekommt per Build-Setting:

- `PRODUCT_BUNDLE_IDENTIFIER` (s. Tabelle oben)
- `APP_DISPLAY_NAME` → Springboard-Name (`Diary Beta` mit Suffix)
- `APP_ENV` → Wird in `Info.plist` injiziert, zur Laufzeit per
  `Bundle.main.object(forInfoDictionaryKey: "APP_ENV")` lesbar
- `BACKEND_ENDPOINT_DEFAULT` → wird beim ersten App-Launch als
  Default-Endpoint übernommen (kann vom User in Settings überschrieben
  werden, aber baked-in für Tester)

Sichtbares Zeichen für Tester: **`EnvBadge`** auf WelcomeView und in
SettingsView. Prod-Builds zeigen kein Badge.

## Erforderliche GitHub-Secrets & Variables

Bevor irgendein Deploy funktioniert, in `Settings → Secrets and variables`
auf Repo- oder Environment-Ebene anlegen:

### Repo-Secrets (gelten für beide Stages)

| Secret | Was |
|---|---|
| `DEPLOY_HOST` | DNS-Name oder IP der Docker-Maschine |
| `DEPLOY_USER` | SSH-User mit Docker-Rechten |
| `DEPLOY_SSH_KEY` | Privater Schlüssel (`-----BEGIN OPENSSH PRIVATE KEY-----…`) |
| `APPLE_TEAM_ID` | 10-Zeichen-Apple-Team-ID (Developer-Portal) |
| `ASC_API_KEY_ID` | App-Store-Connect-API-Key-ID (10 Zeichen) |
| `ASC_API_KEY_ISSUER_ID` | API-Issuer-ID (UUID, ASC → Users and Access → Keys) |
| `ASC_API_KEY_BASE64` | Inhalt der `AuthKey_*.p8`-Datei, base64-encoded: `base64 -i AuthKey_*.p8 \| pbcopy` |

### Repo-Variables (öffentlich, in Logs sichtbar)

| Variable | Was |
|---|---|
| `DEPLOY_PORT` | SSH-Port (Standard 22). Default ist 22. |
| `DEPLOY_PATH` | Repo-Pfad auf der Docker-Maschine, z. B. `/srv/fieldworksdiary`. Muss die compose-Files enthalten. |

### Environment-Variables (pro Stage)

In **`Settings → Environments`** zwei Environments anlegen:

#### `staging`

| Variable | Beispiel |
|---|---|
| `STAGING_URL` | `https://staging.fieldworksdiary.org` |

#### `production`

| Variable | Beispiel |
|---|---|
| `PROD_URL` | `https://api.fieldworksdiary.org` |

In der `production`-Environment **Required Reviewers** aktivieren
(dich selbst eintragen) — damit der Deploy-Step nicht ohne Klick
durchgeht. Auch sinnvoll: Deployment-Branch-Limit auf `main`.

### Environment `staging-ios` und `production-ios`

Spiegelung: gleiche Geheimnisse wie oben, eigene Approver für iOS-
Uploads (z. B. wenn du iOS-Releases manueller gaten willst als
Backend-Releases).

## Einmaliges Setup auf der Docker-Maschine

```bash
# 1. SSH ein
ssh ${DEPLOY_USER}@${DEPLOY_HOST}

# 2. Repo klonen
cd /srv
git clone https://gitlab.com/fieldworksdiary/fieldworksdiary-ng.git fieldworksdiary
cd fieldworksdiary

# 3. Verzeichnisse für DB-Volumes anlegen
mkdir -p pb_data_staging pb_data_prod

# 4. ghcr.io-Login (falls Repo privat ist)
echo "$GITHUB_PAT" | docker login ghcr.io -u <user> --password-stdin

# 5. Erstmaliger Pull + Start (Staging)
docker compose -f docker-compose.yml -f docker-compose.staging.yml pull
docker compose -f docker-compose.yml -f docker-compose.staging.yml up -d --no-build

# 6. PocketBase-Admin in Staging einrichten
open http://${DEPLOY_HOST}:8091/_/

# 7. Gleiches für Prod (Port 8090)
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
open http://${DEPLOY_HOST}:8090/_/

# 8. Reverse-Proxy davor (DSM-Web Station / nginx) für TLS-Termination
#    auf staging.fieldworksdiary.org (→ :8091) und
#    api.fieldworksdiary.org (→ :8090).
```

## App-Store-Connect-Setup

Zwei ASC-App-Einträge nötig (eine pro Bundle-ID):

1. **Diary Beta** — `org.fieldworksdiary.staging`
   - Sichtbarkeit: nur „Internal Testers" (kein App-Store-Listing)
   - TestFlight: Internal-Group mit dir + Beta-Testern
2. **Fieldworksdiary** — `org.fieldworksdiary.prod`
   - Sichtbarkeit: zukünftige App-Store-Listing
   - TestFlight: External-Group für breitere Beta vor Submit

Die ASC-API-Key (`AuthKey_*.p8`) hat Zugriff auf **beide** Apps
(Account-Ebene), keine separaten Keys nötig.

## Promotion-Flow

```bash
# Feature ist auf staging, hat Beta-Tester überlebt, ist ready für Prod:
git checkout main
git merge --no-ff staging
git push origin main
# → CI baut prod-Image, lädt iOS hoch — wartet im "production"-
#   Environment auf deine Approval. Im GH-Actions-UI auf
#   „Review deployments" → genehmigen.
```

Wenn der Deploy danach hängenbleibt: `docs/DISASTER_RECOVERY.md` lesen,
Pre-Deploy-Backup (vom Workflow erzeugt) liegt unter
`pb_data_prod_backups/` auf der Docker-Maschine.

## Versionierung

`MARKETING_VERSION` (= App-Store-Version) wird **manuell** in
`ios/project.yml` gepflegt. `CURRENT_PROJECT_VERSION` (Build-Number)
sollte ebenfalls bei jedem Release inkrementieren — ASC akzeptiert
keinen doppelten Build-Number. Empfehlung: vor `git push origin main`
beides hochziehen, dann Tag setzen:

```bash
git tag -s v0.2.0 -m "release v0.2.0"
git push origin v0.2.0
```

Der Tag-Push triggert nochmal die deploy-prod-Pipeline; mit Tag-Match
in `docker/metadata-action` wird das Image zusätzlich als
`ghcr.io/.../fieldworksdiary:0.2.0` getaggt.
