# Disaster Recovery

Wie wir das Backend wiederherstellen, wenn `pb_data/` weg ist (Host-
Crash, versehentliches `rm`, korrupte Migration, gestohlene Docker-Maschine).

## TL;DR — Restore in 5 Minuten

```bash
# 1. Letztes Backup finden
ls -1t ~/Backups/fieldworksdiary/pbdata-*.tar.gz | head -1

# 2. Backend stoppen
docker compose down

# 3. Aktuelles pb_data wegsichern (falls noch da)
mv backend/pb_data backend/pb_data.broken-$(date +%s) 2>/dev/null || true

# 4. Backup entpacken
mkdir -p backend/pb_data
tar -xzf ~/Backups/fieldworksdiary/pbdata-2026-…Z.tar.gz -C backend/pb_data

# 5. Backend wieder hoch
docker compose up -d

# 6. Smoke-Test
curl -fsS http://localhost:8090/api/health
```

Erwarte: `/api/health` antwortet 200 innerhalb 5 s. Wenn nicht →
`docker compose logs`, häufigster Fall ist eine Migration, die mit dem
Backend-Image-Stand nicht zusammenpasst (siehe „Migrations-Drift" unten).

## Backup-Strategie (Soll-Stand)

- **Lokal**: tägliche Snapshots via `scripts/backup-pbdata.sh` →
  `~/Backups/fieldworksdiary/`, Retention 30.
- **Offsite**: rsync-Spiegel auf separates Volume (NAS, externe SSD).
  TODO: Cron-Eintrag fürs Offsite-Sync etablieren, sobald Ziel-Volume
  feststeht. Mindeste Anforderung: **2 verschiedene physische Geräte**.
- **launchd-Job**: `scripts/backup-pbdata.launchd.plist` ist die Vorlage.
- **Test**: monatlich einen Restore in ein temporäres `pb_data_test/`
  durchspielen — Restore-Übung erkennt korrupte Backups, bevor man sie
  ernsthaft braucht.

### Was im Backup drin ist

| Pfad | Was | Format |
|---|---|---|
| `data.db` | Application-Datenbank (Samples, Excursions, Users, Determinations, …) | SQLite (online-konsistente Kopie via `.backup`) |
| `logs.db` | PocketBase-internes Access-Log | SQLite |
| `storage/` | Permit-PDFs, generierte Label-PDFs, sonstige Uploads | Verzeichnis-Baum |

### Was im Backup **nicht** drin ist

- **PB-Admin-Account-Passwort** (steckt in `data.db` als bcrypt-Hash) —
  kommt mit zurück, falls vor Backup gesetzt.
- **TLS-Zertifikate** (Reverse-Proxy davor regelt das, nicht PocketBase).
- **Docker-Image** selbst — separat aus Registry / lokal pullen.
- **JWT-Signing-Key** (PB-internal in `data.db` `_settings` → kommt mit).
- **iOS-Keychain**-Token: laufen einfach ab, User loggt sich neu ein.

## Szenarien

### A) `pb_data/` versehentlich gelöscht

→ Standard-Restore von oben. Datenverlust: alles seit dem letzten
Backup (= max. 24 h, wenn der launchd-Job läuft).

### B) `data.db` korrumpiert (Disk-Fehler)

Symptom: PocketBase startet nicht, Log zeigt `database disk image is
malformed` oder ähnlich.

```bash
# 1. Versuch: SQLite-Integrity prüfen
sqlite3 backend/pb_data/data.db 'PRAGMA integrity_check;'

# 2a. Wenn nur einzelne Pages defekt:
sqlite3 backend/pb_data/data.db '.recover' > recovered.sql
# Vorsicht: .recover bricht Foreign-Key-Konsistenz möglicherweise auf —
# besser direkt zu Restore wechseln (2b).

# 2b. Direkt-Restore vom letzten Backup (empfohlen):
# → siehe TL;DR
```

### C) Migrations-Drift (Image-Update + DB nicht synchron)

Symptom: Docker-Image vX startet gegen `data.db`, die mit Image-Stand
vY (Y > X) migriert wurde. Schema-Mismatch.

```bash
# Optionen, in Reihenfolge der Präferenz:
# 1. Auf Image-Stand vY zurück (rolling back the binary, not the data)
#    docker compose pull <vY> && docker compose up -d
# 2. Letzten Backup-Stand laden, der zu vX passt — Daten-Verlust seit
#    Backup-Zeitpunkt einkalkuliert.
```

**Vermeidung**: Vor jedem Backend-Deploy ein frisches Backup ziehen,
siehe `RELEASE_CHECKLIST.md`.

### D) Storage-Files verschwunden, DB intakt

Permit-PDFs / Label-PDFs sind in `pb_data/storage/` weg, aber DB hat
noch Referenzen. Symptom: Download-Endpoint liefert 404.

```bash
# Restore nur storage/ aus Backup:
TMP=$(mktemp -d)
tar -xzf ~/Backups/fieldworksdiary/pbdata-…tar.gz -C "$TMP"
docker compose down
rsync -av "$TMP/storage/" backend/pb_data/storage/
docker compose up -d
```

### E) Host komplett verloren (Docker-Maschine gestohlen / abgebrannt)

```bash
# 1. Neuen Host (Mac/Linux mit Docker) bereitstellen.
# 2. Repo clonen:
git clone https://gitlab.com/fieldworksdiary/fieldworksdiary-ng.git
cd fieldworksdiary-ng
# 3. Backup-Volume mounten oder Backup-Datei runterladen.
# 4. Restore wie TL;DR.
# 5. iOS-Clients: Endpoint-URL in der App auf neuen Host umstellen
#    (Settings → Backend-Endpoint). Re-Login.
```

Realistic Recovery-Time-Objective (RTO): **30 min**, sofern Backup auf
erreichbarem Volume liegt.
Realistic Recovery-Point-Objective (RPO): **24 h**, mit täglichem
launchd-Backup. Kürzer bei häufigerem Backup-Cron (alle 6 h: RPO 6 h).

## Restore-Übung

Einmal im Quartal einplanen — sonst weiß man nicht, ob Backups wirklich
funktionieren.

```bash
# Aus dem produktivsten Backup ein Test-pb_data_restored/ bauen:
LATEST=$(ls -1t ~/Backups/fieldworksdiary/pbdata-*.tar.gz | head -1)
TESTDIR=$(mktemp -d)
mkdir -p "$TESTDIR/pb_data"
tar -xzf "$LATEST" -C "$TESTDIR/pb_data"

# Test-Backend hochfahren auf abweichendem Port (Test-Container):
cd "$TESTDIR"
cp /path/to/repo/docker-compose.yml .
# Volume-Pfad in der lokalen compose-Kopie auf $TESTDIR/pb_data zeigen,
# Port-Mapping auf 18090:8090.
docker compose -p wapp-restore-test up -d

# Verifizieren:
curl -fsS http://localhost:18090/api/health    # 200
curl -fsS http://localhost:18090/api/collections/samples/records | jq '.totalItems'

# Aufräumen:
docker compose -p wapp-restore-test down -v
rm -rf "$TESTDIR"
```

Dokumentieren: Datum, Backup-Datei, Ergebnis — als kurzen Eintrag in
`PHASES.md` oder eigenem `docs/restore-drills.md`.
