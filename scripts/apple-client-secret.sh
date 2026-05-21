#!/usr/bin/env bash
# Erzeugt einen JWT-`client_secret` für Apple-Sign-In.
# Apple's OAuth2-`client_secret` ist KEIN normales Passwort, sondern
# ein selbst-signierter JWT mit dem .p8-Schlüssel.
#
# Aufruf:
#   bash scripts/apple-client-secret.sh \
#     --team-id  AB12CD34E5 \
#     --key-id   7XK4F9D2AB \
#     --client   org.fieldworksdiary.dev \
#     --key-file ~/Keys/AuthKey_7XK4F9D2AB.p8
#
# Gibt den JWT auf stdout aus. Pro Stage gesondert generieren —
# der "client"-Wert ist die Bundle-ID, gegen die der Authorization-
# Code ausgestellt wurde.
#
# Validity: maximal 180 Tage. Wir setzen 178 Tage als Sicherheits-
# Margin. Vor Ablauf muss der JWT erneuert und im PocketBase-Admin-
# UI ausgetauscht werden — sonst schlägt Apple-Login mit 400.

set -euo pipefail

TEAM_ID=""
KEY_ID=""
CLIENT_ID=""
KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team-id)   TEAM_ID="$2";   shift 2 ;;
    --key-id)    KEY_ID="$2";    shift 2 ;;
    --client)    CLIENT_ID="$2"; shift 2 ;;
    --key-file)  KEY_FILE="$2";  shift 2 ;;
    *) echo "Unbekanntes Flag: $1" >&2; exit 1 ;;
  esac
done

for var in TEAM_ID KEY_ID CLIENT_ID KEY_FILE; do
  if [ -z "${!var}" ]; then
    echo "Fehlt: --${var,,}" >&2
    exit 1
  fi
done

if [ ! -f "$KEY_FILE" ]; then
  echo "Key-File nicht gefunden: $KEY_FILE" >&2
  exit 1
fi

NOW=$(date +%s)
EXP=$((NOW + 60 * 60 * 24 * 178)) # 178 Tage

HEADER=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | \
  openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
PAYLOAD=$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"https://appleid.apple.com","sub":"%s"}' \
  "$TEAM_ID" "$NOW" "$EXP" "$CLIENT_ID" | \
  openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | \
  openssl dgst -sha256 -sign "$KEY_FILE" | \
  openssl asn1parse -inform DER | \
  awk -F: '/INTEGER/ {gsub(/ /,""); printf "%s",$4}' | \
  xxd -r -p | \
  openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIGNATURE"

echo "" >&2
echo "Gültig bis: $(date -r "$EXP")" >&2
echo "Erneuern spätestens am: $(date -r $((EXP - 30 * 86400)))" >&2
