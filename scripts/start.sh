#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_docker
"${ML_COMPOSE[@]}" config --quiet
"${MON_COMPOSE[@]}" config --quiet
"${ML_COMPOSE[@]}" up -d --build --wait --wait-timeout 420
"${MON_COMPOSE[@]}" up -d --wait --wait-timeout 240
"$REPO_ROOT/scripts/healthcheck.sh"
