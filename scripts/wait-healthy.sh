#!/usr/bin/env bash
# Observe automatic recovery without starting or recreating any container.
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
report=$(mktemp)
trap 'rm -f -- "$report"' EXIT
for attempt in {1..90}; do
    if "$REPO_ROOT/scripts/healthcheck.sh" > "$report" 2>&1; then
        cat "$report"
        exit 0
    fi
    printf 'Waiting for automatic recovery (%s/90)\n' "$attempt"
    sleep 5
done
cat "$report" >&2
echo 'Services did not automatically become healthy.' >&2
exit 1
