#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_docker
mkdir -p "$REPO_ROOT/.runtime"
chmod 0700 "$REPO_ROOT/.runtime"
report=$(mktemp "$REPO_ROOT/.runtime/smoke.XXXXXX")
trap 'rm -f -- "$report"' EXIT
"${ML_COMPOSE[@]}" exec -T mlflow python - "$@" < "$REPO_ROOT/scripts/smoke-test.py" > "$report"
python3 - "$report" <<'PY'
import json,re,sys
with open(sys.argv[1]) as stream:
    result=json.load(stream)
assert result['result']=='passed'
assert re.fullmatch(r'[a-f0-9]{32}',result['run_id'])
PY
cat "$report"
mv -- "$report" "$REPO_ROOT/.runtime/last-smoke.json"
echo 'Saved non-secret test identifiers in .runtime/last-smoke.json'
