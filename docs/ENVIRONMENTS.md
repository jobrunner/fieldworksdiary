# Environments — Dev / Staging / Production

Drei Stages. Die Tabelle ist die kurze Wahrheit, der Rest des Dokuments
füllt die Details. Deployt wird manuell (siehe „Build und Deploy“).

| Stage | Branch | Bundle-ID (iOS) | Tabularius-URL | Port | Volume | TestFlight-Track |
|---|---|---|---|---|---|---|
| **Dev** | beliebig (lokal) | `app.legulus.dev` | `https://tabularius.tunnel.legulus.app` (sish-Tunnel auf localhost) | 8090 | `./tabularius/pb_data/` | — |
| **Staging** | `staging` | `app.legulus.staging` | `https://tabularius-stage.legulus.app` (noch nicht aufgesetzt) | 8091 | `./pb_data_staging/` | Internal Beta |
| **Production** | `main` | `app.legulus.prod` | `https://tabularius.legulus.app` | 8090 | `./pb_data_prod/` | External / App Store |

Die iOS-App heißt **Legulus**, das Backend (PocketBase als Go-Library)
**Tabularius** und liegt in `tabularius/`. Das Repo heißt `legulus`, das
Image `ghcr.io/jobrunner/tabularius`.

Der Dev-Tunnel ist ein SSH-Tunnel über sish auf die lokale Instanz
(Port 8090). Ein Gerät erreicht sie damit per HTTPS, ohne ATS-Ausnahme
und ohne gemeinsames WLAN. Läuft der Tunnel nicht, antwortet die
Tunnel-URL mit 404.

```bash
make tabularius-tunnel                    # Dev-Backend auf 8090
make tabularius-tunnel TUNNEL_PORT=8092   # Test-Instanz der iOS-Tests
```

Das Ziel prüft vorher, ob auf dem Port ein Backend antwortet. Zeigt der
Tunnel auf die Test-Instanz, scheitern Apple-Login (andere Bundle-ID)
und die Konten des Dev-Backends; außerdem setzt jeder iOS-Testlauf diese
Instanz zurück. Schlüssel, Host und Tunnel-Name lassen sich über
`TUNNEL_KEY`, `TUNNEL_HOST` und `TUNNEL_NAME` überschreiben.

Staging und Production laufen **isoliert** in eigenen Docker-Containern
(`tabularius-staging` vs `tabularius-prod`) mit eigenen
SQLite-Volumes. Ein Crash der Staging-Datenbank kann Prod nicht treffen.

## Build und Deploy

- Jeder Push auf `main` baut über `.github/workflows/docker-release.yml`
  das Backend-Image (amd64 + arm64) und legt es in der GitHub Container
  Registry ab: `ghcr.io/jobrunner/tabularius`. Ein main-Build
  bekommt nur den Short-SHA (`<kurz>`, ohne Präfix) und `edge`, das
  bewusst auf den neuesten Stand von `main` wandert. Jedes Image erhält
  eine signierte Build-Provenance (`gh attestation verify`). Ein
  Trivy-Scan läuft danach advisory (SARIF im Security-Tab), er
  blockiert nichts.
- Versions-Tags (`X.Y.Z`, `X.Y`, `X`, `latest`) entstehen nur beim
  Release, siehe „Versionierung“. `X.Y.Z` zeigt danach immer auf
  dasselbe Image und wird nie umgehängt.
- **Deployt wird manuell** auf der Docker-Maschine (siehe „Manuelles Deploy“),
  wie bei Ortus. GitHub hat keinen Zugriff auf den Host - es gibt
  bewusst keinen SSH-Deploy-Job und keine Host-Secrets im Repo.
- iOS-Builds gehen manuell über Xcode (Archive → TestFlight), es gibt
  keinen CI-Upload.
- Ein Staging-Image wird zurzeit nicht automatisch gebaut. Bei Bedarf
  lokal bauen oder `docker-release.yml` um einen `staging`-Trigger
  erweitern.

## Externe Dienste des Backends

| Variable | Dienst | Ohne Wert |
|---|---|---|
| `ORTUS_BASE_URL` | Ortus (Ortsdaten, Höhe, MTB) | keine Orts-Anreicherung |
| `TEMPUS_BASE_URL` | Tempus (Wetter, Klima, Astronomie), z.B. `https://tempus.example` | keine Wetter-Anreicherung, kein stündlicher Nachzieh-Lauf |

Beide Variablen haben in den Compose-Dateien einen Default und lassen
sich über die Umgebung überschreiben. Ein ausdrücklich leerer Wert
(`TEMPUS_BASE_URL=`) schaltet Tempus ab. In `docker-compose.test.yml` ist
`TEMPUS_BASE_URL` leer, damit die iOS-Tests nicht vom Netz abhängen.
Der Nachzieh-Lauf startet stündlich zur Minute 7 und fragt höchstens
200 Proben pro Lauf ab.

### Bestehende Proben nachfüllen (`tempus-backfill`)

Proben, die vor der Tempus-Anbindung angelegt wurden, haben einen leeren
`conditions_status` und werden vom stündlichen Lauf nicht angefasst. Das
Kommando füllt sie nach, älteste zuerst:

```bash
docker compose exec tabularius /app/tabularius tempus-backfill
docker compose exec tabularius /app/tabularius tempus-backfill --limit 500 --interval 1s
```

Ein Lauf bearbeitet höchstens `--limit` Proben (Default 200) mit einer
Pause von `--interval` (Default 2 s) und gibt am Ende aus, wie viele
abgefragt wurden und wie viele noch warten. Er lässt sich jederzeit
abbrechen und wiederholen. Jede Probe kostet Tempus und die Wetterquelle
dahinter eine volle Abfrage (die Klima-Normalen sind der teure Teil);
bei vielen Proben deshalb über mehrere Tage verteilen. Scheitert eine
Abfrage, bleibt die Probe `pending` und der stündliche Lauf versucht sie
erneut. Der Pfad des Binaries im Container steht im `Dockerfile`.

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

Prod zieht `ghcr.io/jobrunner/tabularius:${TABULARIUS_VERSION}`, die
Version steht in der `.env` auf der Docker-Maschine (`TABULARIUS_VERSION=0.1.0`).
Fehlt sie, bricht compose ab. X.Y.Z gibt es nur für Releases und zeigt
immer auf dasselbe Image; jeder main-Build bekommt seinen Short-SHA und
`edge` (wandert mit). Staging nutzt `TABULARIUS_IMAGE` mit Default
`:staging`, Override per ENV:

```bash
TABULARIUS_IMAGE=ghcr.io/.../tabularius:staging-abc1234 \
  docker compose -f docker-compose.yml -f docker-compose.staging.yml up -d --no-build
```

## iOS-Schemes

`ios/project.yml` definiert vier Configs (Debug, Test, Staging, Release)
und vier Schemes:

| Scheme | Config | Wofür |
|---|---|---|
| `Legulus` | Debug | Lokale Entwicklung - „Legulus Dev“, DEV-Icon, Tunnel (Gerät) bzw. `http://localhost:8090` (Simulator) |
| `Legulus-Test` | Test | Testläufe gegen die Test-Instanz - „Legulus Test“ (`app.legulus.test`), DEV-Icon, `http://localhost:8092` |
| `Legulus-Staging` | Staging | TestFlight-Beta-Builds - „Legulus Beta“, BETA-Icon, tabularius-stage |
| `Legulus-Prod` | Release | App-Store-Submits - „Legulus“, Prod-Icon, tabularius |

Jede Config bekommt per Build-Setting:

- `PRODUCT_BUNDLE_IDENTIFIER` (s. Tabelle oben)
- `APP_DISPLAY_NAME` → Springboard-Name (`Legulus Dev`, `Legulus Beta`, `Legulus`)
- `ASSETCATALOG_COMPILER_APPICON_NAME` → `AppIcon-Dev`, `AppIcon-Staging`,
  `AppIcon` (Dev und Beta mit farbigem Banner, damit die drei Apps
  nebeneinander auf dem Homescreen unterscheidbar sind)
- `APP_ENV` → Wird in `Info.plist` injiziert, zur Laufzeit per
  `Bundle.main.object(forInfoDictionaryKey: "APP_ENV")` lesbar
- `TABULARIUS_ENDPOINT_DEFAULT` → wird beim ersten App-Launch als
  Default-Endpoint übernommen (kann vom User in Settings überschrieben
  werden, aber baked-in für Tester)

Im Simulator bekommt die Debug-Config `http://localhost:8090` statt des
Tunnels eingebacken (`TABULARIUS_ENDPOINT_DEFAULT[sdk=iphonesimulator*]`):
der Simulator teilt sich das Netz mit dem Mac. Ein bereits gespeicherter
Endpoint bleibt, er lässt sich in den Settings ändern.

### Tests gegen die Test-Instanz

`Legulus-Test` hat eine eigene Bundle-ID und damit im Simulator
einen eigenen App-Container, getrennt von „Legulus Dev“. Die App zeigt
auf eine eigene Tabularius-Instanz aus `docker-compose.test.yml`
(eigenständiges Compose-File, kein Overlay): Container
`tabularius-test`, Port 8092, Daten in
`tabularius/pb_data_test`. Sie läuft neben der Dev-Instanz.

Vor jedem Testlauf ruft das Scheme `scripts/reset-test-tabularius.sh`
auf. Das Script stoppt den Container, leert `tabularius/pb_data_test`,
startet neu (die Migrationen bauen das Schema) und legt den festen
Test-Nutzer an. Jeder Lauf beginnt so im selben Zustand. Das
Datenverzeichnis ist gitignored: im Repo stehen die Migrationen und
das Script, aus denen die Datenbank entsteht, nicht die SQLite-Datei.

Xcode ignoriert den Exit-Code einer Pre-Action; deshalb schlägt
zusätzlich `TestTabulariusTests.testTestInstanceIsReachable` fehl, wenn
die Instanz fehlt. `scripts/check-ios.sh` testet in diesem Scheme.

Auch das Scheme `Legulus` testet in der Test-Config mit
derselben Pre-Action (Cmd-U trifft damit nie „Legulus Dev“).
`scripts/test-ios-no-build.sh` ruft das Reset-Script selbst auf, weil
`test-without-building` keine Pre-Action ausführt.

Die UI-Tests (`ios/LegulusUITests/`) steuern die Sitzung über
Launch-Argumente, die nur Debug-Builds auswerten
(`AuthSession.applyUITestSession`): `-UITestsSignedOut true` startet
abgemeldet, zusätzlich `-UITestsSignInEmail`/`-UITestsSignInPassword`
meldet die App beim Start selbst als Test-Nutzer an. Durch das
Login-Formular geht nur der Login-Test. Grund: nach einer Eingabe ins
Passwortfeld bietet iOS 26 „Passwort sichern?“ an; das System-Sheet
erscheint verzögert und verdeckt, was ein Test danach bedienen will.

Den Standort simuliert der Test selbst über
`XCUIDevice.shared.location`; die angelegte Probe löscht er am Ende
wieder. Die Zugangsdaten des Test-Nutzers stehen im Script und in
`TestBackend.swift`.

Sichtbares Zeichen für Tester: **`EnvBadge`** auf WelcomeView und in
SettingsView. Prod-Builds zeigen kein Badge.

## Einmaliges Setup auf der Docker-Maschine

```bash
# 1. SSH ein
ssh <user>@<host>

# 2. Repo klonen
cd /srv
git clone git@github.com:jobrunner/legulus.git legulus
cd legulus

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
#    auf tabularius-stage.legulus.app (→ :8091) und
#    tabularius.legulus.app (→ :8090).
```

## App-Store-Connect-Setup

Zwei ASC-App-Einträge nötig (eine pro Bundle-ID):

1. **Legulus Beta** — `app.legulus.staging`
   - Sichtbarkeit: nur „Internal Testers" (kein App-Store-Listing)
   - TestFlight: Internal-Group mit dir + Beta-Testern
2. **Legulus** — `app.legulus.prod`
   - Sichtbarkeit: zukünftige App-Store-Listing
   - TestFlight: External-Group für breitere Beta vor Submit

Die ASC-API-Key (`AuthKey_*.p8`) hat Zugriff auf **beide** Apps
(Account-Ebene), keine separaten Keys nötig.

## Manuelles Deploy

```bash
# Auf der Docker-Maschine, im Repo-Verzeichnis:
cd /srv/legulus
git pull                                   # compose-Files aktuell halten

# Backup der Prod-DB vor jedem Update (Migrationen laufen beim Start)
cp -a pb_data_prod "pb_data_prod_backups/$(date +%Y%m%d-%H%M%S)"

# Zielversion in .env eintragen (TABULARIUS_VERSION=X.Y.Z)
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
curl -fsS http://localhost:8090/api/health
curl -fsS http://localhost:8090/api/version   # zeigt die laufende Version
```

Zurückrollen: in der `.env` die vorherige Version (oder einen SHA-Tag)
eintragen und das Backup zurückspielen (`docs/DISASTER_RECOVERY.md`).

## Versionierung

release-please pflegt die Version aus den Conventional Commits: Es hält
einen Release-PR offen, der `VERSION`, `MARKETING_VERSION` in
`ios/project.yml` und `CHANGELOG.md` hochzieht. Mit dem Merge dieses PRs
entstehen Tag `vX.Y.Z` und GitHub-Release. Der Tag startet im
Docker-Release den Job `promote`: Er baut **nicht** neu, sondern wartet,
bis das Image des Release-Commits (aus dessen main-Build) existiert und
seine Attestation dieselbe Prüfung besteht wie in `deploy.sh`. Dann
setzt er `X.Y.Z` auf genau diesen Digest, `X.Y`, `X` und `latest` nur,
wenn die Version die höchste ihrer Gruppe ist. Ein schon vorhandenes
`X.Y.Z` mit anderem Digest bricht ab. Das Binary meldet auf dem
Release-Commit `X.Y.Z`, auf allen anderen Builds `X.Y.Z+g<sha>`.
`CURRENT_PROJECT_VERSION`
(Build-Number) bleibt manuell: ASC akzeptiert keine doppelte
Build-Number, also vor jedem Upload hochziehen.
