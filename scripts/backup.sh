#!/usr/bin/env bash
# Consistent cold-copy backup with brief application downtime.
set -Eeuo pipefail
umask 077
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_docker
backup_root=${BACKUP_DIR:-/srv/homelab/backups}
[[ $backup_root == /* ]] || { echo 'BACKUP_DIR must be an absolute path.' >&2; exit 1; }
backup_root=$(realpath -m -- "$backup_root")
case "$backup_root/" in "$REPO_ROOT/"*|/srv/homelab/postgres/*|/srv/homelab/seaweedfs/*|/srv/homelab/uptime-kuma/*)
    echo 'Backup destination must be outside the repo and live service data.' >&2; exit 1;;
esac
mkdir -p -- "$backup_root"
chmod 0700 "$backup_root"
exec 9>"$backup_root/.backup.lock"
flock -n 9 || { echo 'Another backup is running.' >&2; exit 1; }
output=$(mktemp -d "$backup_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
chmod 0700 "$output"
printf '%s\n' 'Backup is incomplete until COMPLETE exists.' > "$output/INCOMPLETE"

mlflow_id=$("${ML_COMPOSE[@]}" ps -q mlflow)
seaweed_id=$("${ML_COMPOSE[@]}" ps -q seaweedfs)
kuma_id=$("${MON_COMPOSE[@]}" ps -q uptime-kuma)
[[ -n $mlflow_id && -n $seaweed_id && -n $kuma_id ]] || {
    echo 'Start all services before backup; no service has been stopped.' >&2; exit 1;
}
# Record services before stopping so failure handling only restarts these.
resume_needed=false
resume() {
    local status=$?
    trap - EXIT INT TERM
    if $resume_needed; then
        "${ML_COMPOSE[@]}" start seaweedfs mlflow || status=1
        "${MON_COMPOSE[@]}" start uptime-kuma || status=1
    fi
    exit "$status"
}
trap resume EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
resume_needed=true
"${ML_COMPOSE[@]}" stop mlflow
"${ML_COMPOSE[@]}" stop seaweedfs
"${MON_COMPOSE[@]}" stop uptime-kuma

# Variables are expanded inside the PostgreSQL container, not on the host.
# shellcheck disable=SC2016
"${ML_COMPOSE[@]}" exec -T postgres sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl' > "$output/postgres.dump"
"${ML_COMPOSE[@]}" exec -T postgres pg_restore --list < "$output/postgres.dump" > "$output/postgres-toc.txt"
# docker cp exports stopped bind-mounted directories without requiring host sudo.
docker cp "$seaweed_id:/data/." - | gzip > "$output/seaweedfs.tar.gz"
docker cp "$kuma_id:/app/data/." - | gzip > "$output/uptime-kuma.tar.gz"
# Include the secret .env deliberately: all archive files are owner-only.
tar -czf "$output/config.tar.gz" -C "$REPO_ROOT" compose scripts docs README.md .gitignore
docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' \
    "$mlflow_id" "$seaweed_id" "$kuma_id" > "$output/images.txt"
(cd -- "$output" && sha256sum postgres.dump seaweedfs.tar.gz uptime-kuma.tar.gz config.tar.gz > SHA256SUMS)
gzip -t "$output/seaweedfs.tar.gz" "$output/uptime-kuma.tar.gz" "$output/config.tar.gz"
"${ML_COMPOSE[@]}" start seaweedfs mlflow
"${MON_COMPOSE[@]}" start uptime-kuma
resume_needed=false
"${ML_COMPOSE[@]}" up -d --wait --wait-timeout 420
"${MON_COMPOSE[@]}" up -d --wait --wait-timeout 240
"$REPO_ROOT/scripts/healthcheck.sh"
rm -- "$output/INCOMPLETE"
touch "$output/COMPLETE"
echo "Backup completed: $output"
echo 'A copy on the same SSD is not a real backup. Copy it to independent storage.'
