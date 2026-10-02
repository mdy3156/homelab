#!/usr/bin/env bash
# Source from repository scripts. Preserve this location when copying scripts.
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Arrays are consumed by the shell scripts which source this file.
# shellcheck disable=SC2034
ML_COMPOSE=(docker compose --project-directory "$REPO_ROOT/compose/ml-platform" -f "$REPO_ROOT/compose/ml-platform/compose.yml")
# shellcheck disable=SC2034
MON_COMPOSE=(docker compose --project-directory "$REPO_ROOT/compose/monitoring" -f "$REPO_ROOT/compose/monitoring/compose.yml")

require_docker() {
    command -v docker >/dev/null || { echo 'Docker is not installed. Run provision-host.sh first.' >&2; exit 1; }
    docker info >/dev/null 2>&1 || {
        echo 'Docker daemon is unavailable. Log in again after docker group membership was added.' >&2
        echo "Alternatively: sg docker -c '$REPO_ROOT/scripts/$(basename -- "$0")'" >&2
        exit 1
    }
}
