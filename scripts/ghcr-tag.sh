#!/usr/bin/env bash
# Tags in ghcr.io lesen und setzen, ohne Image neu zu bauen oder zu
# ziehen. Das Manifest der Quelle wird byte-genau unter den Ziel-Tags
# abgelegt, der Digest bleibt also identisch (und wird nach jedem PUT
# geprüft). Damit bleiben auch Attestationen gültig, die am Digest
# hängen.
#
#   ghcr-tag.sh digest <repo> <tag>              Digest ausgeben, leer wenn es den Tag nicht gibt
#   ghcr-tag.sh copy   <repo> <quelle> <ziel>... Ziel-Tags auf den Digest der Quelle setzen
#
# <quelle> ist ein Tag oder ein Digest (sha256:…). Wurde vorher ein
# Digest geprüft (z.B. seine Attestation), immer den Digest übergeben:
# Ein Tag kann sich zwischen Prüfung und Kopie ändern.
#
# <repo> ohne Registry, z.B. jobrunner/fieldworksdiary. Zugangsdaten
# kommen aus GHCR_USER und GHCR_TOKEN (in Actions: github.actor und
# GITHUB_TOKEN mit packages: write). Ohne beide wird anonym gelesen.
#
# Genutzt von .github/workflows/docker-release.yml (Jobs edge und
# promote).

set -euo pipefail

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

token() {
  local repo="$1" scope="$2"
  local url="https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:${scope}"
  if [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
    curl -fsS -u "${GHCR_USER}:${GHCR_TOKEN}" "$url" | jq -r .token
  else
    curl -fsS "$url" | jq -r .token
  fi
}

header() {
  grep -i "^$1:" | tail -1 | cut -d' ' -f2- | tr -d '\r'
}

# digest <repo> <tag> [token]
digest() {
  local repo="$1" tag="$2" tok="${3:-}"
  [[ -n "$tok" ]] || tok=$(token "$repo" pull)
  local code headers
  headers=$(mktemp)
  code=$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' -I \
    -H "Authorization: Bearer ${tok}" -H "Accept: ${ACCEPT}" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}")
  case "$code" in
    200) header docker-content-digest < "$headers" ;;
    404) ;;
    *) echo "ghcr-tag: HEAD ${repo}:${tag} lieferte HTTP ${code}" >&2; rm -f "$headers"; return 1 ;;
  esac
  rm -f "$headers"
}

# copy <repo> <quelle> <ziel>...
copy() {
  local repo="$1" src="$2"; shift 2
  local tok dir ct want got
  tok=$(token "$repo" pull,push)
  dir=$(mktemp -d)
  curl -fsS -o "$dir/manifest" -D "$dir/headers" \
    -H "Authorization: Bearer ${tok}" -H "Accept: ${ACCEPT}" \
    "https://ghcr.io/v2/${repo}/manifests/${src}"
  ct=$(header content-type < "$dir/headers")
  want="sha256:$(sha256sum "$dir/manifest" 2>/dev/null || shasum -a 256 "$dir/manifest")"
  want="${want%% *}"
  if [[ "$want" != "$(header docker-content-digest < "$dir/headers")" ]]; then
    echo "ghcr-tag: Manifest von ${repo}@${src} passt nicht zum gemeldeten Digest" >&2
    rm -rf "$dir"; return 1
  fi
  if [[ "$src" == sha256:* && "$src" != "$want" ]]; then
    echo "ghcr-tag: angefordert ${src}, geliefert ${want}" >&2
    rm -rf "$dir"; return 1
  fi

  for tag in "$@"; do
    curl -fsS -X PUT -o /dev/null \
      -H "Authorization: Bearer ${tok}" -H "Content-Type: ${ct}" \
      --data-binary @"$dir/manifest" \
      "https://ghcr.io/v2/${repo}/manifests/${tag}"
    got=$(digest "$repo" "$tag" "$tok")
    if [[ "$got" != "$want" ]]; then
      echo "ghcr-tag: ${repo}:${tag} zeigt auf ${got}, erwartet ${want}" >&2
      rm -rf "$dir"; return 1
    fi
    echo "ghcr.io/${repo}:${tag} -> ${want}"
  done
  rm -rf "$dir"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  digest) [[ $# -eq 2 ]] || { echo "usage: $0 digest <repo> <tag>" >&2; exit 2; }; digest "$@" ;;
  copy)   [[ $# -ge 3 ]] || { echo "usage: $0 copy <repo> <quelle> <ziel>..." >&2; exit 2; }; copy "$@" ;;
  *) echo "usage: $0 {digest|copy} ..." >&2; exit 2 ;;
esac
