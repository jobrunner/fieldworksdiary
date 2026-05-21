# Release Checklist

Pre-Flight für Backend- und iOS-Releases. Abhakliste, keine Theorie.
Reihenfolge ist relevant: Backend zuerst, weil iOS gegen ein laufendes
Backend buildet.

**Branch-Flow** (Details: [`docs/ENVIRONMENTS.md`](ENVIRONMENTS.md)):
`feature/*` → PR auf `staging` → automatischer Staging-Deploy →
PR auf `main` → manueller Approval-Gate → Prod-Deploy.

## Vorab (für beide Pfade)

- [ ] **Feature-Branch nach `staging` gemergt**, dort 2–3 Tage gegen
      Beta-TestFlight + Staging-Backend gelaufen, keine Crashes in
      MetricKit-Reports
- [ ] `git status` sauber, alle Änderungen committed
- [ ] Promotion `staging → main` ist ein expliziter PR mit
      Self-Review-Pass
- [ ] `bash scripts/check.sh` lokal **grün** (Backend, iOS, Security)
- [ ] CI auf `main` grün (alle Workflows in `.github/workflows/`)
- [ ] `PHASES.md` aktualisiert: Phase, von der wir kommen, ist als
      `done` markiert
- [ ] **Backup von `pb_data/`** angelegt:
      `KEEP_LAST=60 bash scripts/backup-pbdata.sh /Volumes/Backup/wapp`
- [ ] CHANGELOG mit `git-cliff --unreleased --tag vX.Y.Z` aktualisiert,
      Top-Sektion auf Lesbarkeit gegengelesen

## Backend-Release (Docker-Image)

- [ ] Version-Tag vergeben — SemVer:
      - `patch` für Bugfix-only-Releases
      - `minor` für additive Features
      - `major`/Breaking nur vor `v1.0.0` ohne Vorlauf, danach mit ADR
- [ ] `git tag -s vX.Y.Z -m "release vX.Y.Z"` (signiert, falls GPG da)
- [ ] `docker compose build` lokal — ohne Cache:
      `docker compose build --no-cache --pull`
- [ ] `docker image inspect …` zeigt korrekte Labels (Git-SHA, Version)
      — TODO: Labels im Dockerfile per `ARG`/`LABEL` einbauen
- [ ] Image-Scan: `trivy image fieldworksdiary:vX.Y.Z` — HIGH/CRITICAL: 0
- [ ] **Dry-Run**: Image lokal hochfahren, Postman-Collection grün:
      ```
      newman run tests/Fieldworksdiary.postman_collection.json \
        --env-var baseUrl=http://localhost:8090 --delay-request 3000
      ```
- [ ] Deploy auf dem Docker-Host (oder Ziel-Host):
      ```
      docker compose pull && docker compose up -d
      ```
- [ ] Smoke-Test gegen Prod: `curl https://<host>/api/health` → 200
- [ ] PocketBase-Admin-UI erreichbar nur über VPN/Wireguard
- [ ] Logs gesund (kein Recover-Spam, kein 5xx-Burst):
      `docker compose logs --since=10m`

## iOS-Release (TestFlight → App Store)

### Vorbereitung
- [ ] `ios/project.yml` Marketing-Version `MARKETING_VERSION` hochgezählt
- [ ] `CURRENT_PROJECT_VERSION` (Build-Number) inkrementiert
- [ ] `cd ios && xcodegen generate`
- [ ] `PrivacyInfo.xcprivacy` reviewt: nur tatsächlich verwendete
      Required-Reason-APIs gelistet
- [ ] `AppConfig.privacyPolicyURL` zeigt auf eine **live-erreichbare**
      Datenschutzerklärung (`docs/datenschutz.md`-Inhalt gehosted)
- [ ] **Snapshot-Tests** und **A11y-Audit** lokal grün:
      ```
      bash scripts/check-ios.sh
      ```

### App-Store-Connect
- [ ] Privacy-Policy-URL in ASC eingetragen (gleiche wie in App)
- [ ] App-Privacy-Antworten ausgefüllt (Email, Name, Precise Location:
      linked, not tracking, App Functionality)
- [ ] Localized Description (DE/EN) review
- [ ] Screenshots aktualisiert (mind. 6.7", 6.5")
- [ ] What's New: Top-Bullets aus CHANGELOG

### Build & Upload
- [ ] In Xcode: Scheme **Fieldworksdiary**, Destination **Any iOS Device (arm64)**
- [ ] `Product → Archive`
- [ ] Validation: 0 errors, Warnings (Privacy-Manifest etc.) reviewt
- [ ] Distribute → **App Store Connect → Upload**
- [ ] Auf TestFlight: Internal-Group durchschicken, 1 Smoke-Run am Gerät
- [ ] **24 h warten** auf MetricKit-Reports im Xcode-Organizer; auf
      Crashes/Hangs prüfen
- [ ] **External-Beta** (optional): falls breitere Tester nötig
- [ ] Submit for Review im ASC

### Post-Release
- [ ] GitHub-Release-Note aus dem CHANGELOG erstellt
      (`gh release create vX.Y.Z --notes-from-tag`)
- [ ] `PHASES.md`: Release-Eintrag mit Datum + Build-Number
- [ ] Monitoring: 48 h MetricKit + PocketBase-Logs gegenchecken

## Rollback-Punkte

| Stage | Wie zurück |
|---|---|
| Backend nach Deploy | `docker compose up -d` mit altem Tag aus Registry/Local-Image |
| Backend mit DB-Migration | Restore aus letztem `pb_data`-Backup, siehe `docs/DISASTER_RECOVERY.md` |
| iOS TestFlight | Älteren Build in TestFlight aktivieren — Apple behält alle Builds |
| iOS App Store | App-Store-Connect → vorigen Build „erneut einreichen" oder Schnell-Hotfix-Release |

Wenn ein Rollback DB-Migrations rückgängig macht, **immer** auf das
letzte `pbdata-…tar.gz` zurückspielen — niemals manuell SQL-revertieren.
