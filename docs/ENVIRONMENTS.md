# Environments — Dev / Staging / Production

Drei Stages. Die Tabelle ist die kurze Wahrheit, der Rest des Dokuments
füllt die Details. Deployt wird manuell (siehe „Build und Deploy“).

| Stage | Branch | Bundle-ID (iOS) | Backend-Host | Port | Volume | TestFlight-Track |
|---|---|---|---|---|---|---|
| **Dev** | beliebig (lokal) | `org.fieldworksdiary.dev` | localhost | 8090 | `./backend/pb_data/` | — |
| **Staging** | `staging` | `org.fieldworksdiary.staging` | gleiche Docker-Maschine | 8091 | `./pb_data_staging/` | Internal Beta |
| **Production** | `main` | `org.fieldworksdiary.prod` | gleiche Docker-Maschine | 8090 | `./pb_data_prod/` | External / App Store |

Staging und Production laufen **isoliert** in eigenen Docker-Containern
(`fieldworksdiary-backend-staging` vs `fieldworksdiary-backend-prod`) mit eigenen
SQLite-Volumes. Ein Crash der Staging-Datenbank kann Prod nicht treffen.

## Build und Deploy

- Jeder Push auf `main` baut über `.github/workflows/docker-release.yml`
  das Backend-Image (amd64 + arm64) und legt es in der GitHub Container
  Registry ab: `ghcr.io/jobrunner/fieldworksdiary` mit den Tags `prod`,
  `latest` und `sha-<kurz>`. Ein Trivy-Scan läuft danach advisory
  (Security-Tab), er blockiert nichts.
- **Deployt wird manuell** auf der Docker-Maschine (siehe „Manuelles Deploy“),
  wie bei Ortus. GitHub hat keinen Zugriff auf den Host - es gibt
  bewusst keinen SSH-Deploy-Job und keine Host-Secrets im Repo.
- iOS-Builds gehen manuell über Xcode (Archive → TestFlight), es gibt
  keinen CI-Upload.
- Ein Staging-Image wird zurzeit nicht automatisch gebaut. Bei Bedarf
  lokal bauen oder `docker-release.yml` um einen `staging`-Trigger
  erweitern.

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

Das Default-`BACKEND_IMAGE` zeigt auf `ghcr.io/jobrunner/fieldworksdiary:staging`
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

## Einmaliges Setup auf der Docker-Maschine

```bash
# 1. SSH ein
ssh <user>@<host>

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
open http://<host>:8091/_/

# 7. Gleiches für Prod (Port 8090)
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
open http://<host>:8090/_/

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

## Manuelles Deploy

```bash
# Auf der Docker-Maschine, im Repo-Verzeichnis:
cd /srv/fieldworksdiary
git pull                                   # compose-Files aktuell halten

# Backup der Prod-DB vor jedem Update (Migrationen laufen beim Start)
cp -a pb_data_prod "pb_data_prod_backups/$(date +%Y%m%d-%H%M%S)"

docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
curl -fsS http://localhost:8090/api/health
```

Zurückrollen: `BACKEND_IMAGE=ghcr.io/jobrunner/fieldworksdiary:sha-<kurz>`
setzen und das Backup zurückspielen (`docs/DISASTER_RECOVERY.md`).

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

Ein Tag baut kein eigenes Image; das Image zum Release ist das
`sha-<kurz>` des getaggten Commits.
