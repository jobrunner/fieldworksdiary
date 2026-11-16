#!/usr/bin/env bash
# Setzt die Test-Instanz von Tabularius neu auf (docker-compose.test.yml,
# localhost:8092): Container stoppen, `tabularius/pb_data_test` leeren,
# starten (die Migrationen bauen das Schema), festen Test-Nutzer anlegen.
# Jeder Testlauf beginnt damit im selben Zustand.
#
# Aufrufer: `scripts/check-ios.sh` und die Test-Pre-Action des Schemes
# `Legulus-Test` (dort mit Xcodes Minimal-PATH, deshalb die
# Docker-Pfade unten).
#
# Die Zugangsdaten des Test-Nutzers stehen auch in
# `ios/LegulusUITests/TestBackend.swift` - beide Stellen
# zusammen ändern.
#
# Aufruf: bash scripts/reset-test-tabularius.sh
# Exit:   0 = Instanz läuft und Test-Nutzer kann sich anmelden, 1 = Fehler

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
BASE_URL="http://localhost:8092"
DATA_DIR="$ROOT/tabularius/pb_data_test"
WAIT_SECONDS="${TABULARIUS_WAIT_SECONDS:-120}"
TEST_EMAIL="uitest@legulus.example"
TEST_PASSWORD="legulus-uitest-1"

say() { echo "reset-test-tabularius: $*" >&2; }
compose() { docker compose -f docker-compose.test.yml "$@"; }
healthy() { curl -fsS -m 3 "$BASE_URL/api/health" >/dev/null 2>&1; }

if ! command -v docker >/dev/null 2>&1; then
  say "docker nicht gefunden"
  exit 1
fi

compose down --remove-orphans >&2 || { say "docker compose down fehlgeschlagen"; exit 1; }
rm -rf "$DATA_DIR"

if ! compose up -d --build >&2; then
  say "docker compose up fehlgeschlagen"
  exit 1
fi

STARTED=0
for _ in $(seq 1 "$WAIT_SECONDS"); do
  if healthy; then STARTED=1; break; fi
  /bin/sleep 1
done
if [ "$STARTED" -ne 1 ]; then
  say "$BASE_URL/api/health antwortet nach ${WAIT_SECONDS}s nicht"
  exit 1
fi

CREATE_STATUS=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"passwordConfirm\":\"$TEST_PASSWORD\",\"display_name\":\"Test Nutzer\",\"abbreviation\":\"T. Nutzer\"}" \
  "$BASE_URL/api/collections/users/records")
if [ "$CREATE_STATUS" != "200" ]; then
  say "Test-Nutzer anlegen fehlgeschlagen (HTTP $CREATE_STATUS)"
  exit 1
fi

AUTH_STATUS=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" \
  "$BASE_URL/api/collections/users/auth-with-password")
if [ "$AUTH_STATUS" != "200" ]; then
  say "Anmeldung des Test-Nutzers fehlgeschlagen (HTTP $AUTH_STATUS)"
  exit 1
fi
