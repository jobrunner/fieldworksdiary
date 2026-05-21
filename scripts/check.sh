#!/usr/bin/env bash
# Top-Level QA-Suite — ruft Backend- und iOS-Checks auf und gibt Summary aus.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKEND_EXIT=0
IOS_EXIT=0
SEC_EXIT=0

printf '\n\033[1;36m═══════════════════════════════════════════\033[0m\n'
printf '\033[1;36m  Backend-Checks\033[0m\n'
printf '\033[1;36m═══════════════════════════════════════════\033[0m\n'
bash "$ROOT/scripts/check-backend.sh" || BACKEND_EXIT=$?

printf '\n\033[1;36m═══════════════════════════════════════════\033[0m\n'
printf '\033[1;36m  iOS-Checks\033[0m\n'
printf '\033[1;36m═══════════════════════════════════════════\033[0m\n'
bash "$ROOT/scripts/check-ios.sh" || IOS_EXIT=$?

printf '\n\033[1;36m═══════════════════════════════════════════\033[0m\n'
printf '\033[1;36m  Security-Checks\033[0m\n'
printf '\033[1;36m═══════════════════════════════════════════\033[0m\n'
bash "$ROOT/scripts/check-security.sh" || SEC_EXIT=$?

printf '\n\033[1;36m═══════════════════════════════════════════\033[0m\n'
printf '\033[1;36m  Summary\033[0m\n'
printf '\033[1;36m═══════════════════════════════════════════\033[0m\n'
[ "$BACKEND_EXIT" -eq 0 ] && printf '  Backend:  \033[1;32mOK\033[0m\n'  || printf '  Backend:  \033[1;31mFAIL (exit %d)\033[0m\n' "$BACKEND_EXIT"
[ "$IOS_EXIT"     -eq 0 ] && printf '  iOS:      \033[1;32mOK\033[0m\n'  || printf '  iOS:      \033[1;31mFAIL (exit %d)\033[0m\n' "$IOS_EXIT"
[ "$SEC_EXIT"     -eq 0 ] && printf '  Security: \033[1;32mOK\033[0m\n'  || printf '  Security: \033[1;31mFAIL (exit %d)\033[0m\n' "$SEC_EXIT"

exit $((BACKEND_EXIT + IOS_EXIT + SEC_EXIT))
