#!/usr/bin/env bash
# Install the Docker-only IPv4 readiness guard; do not restart Docker here.
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'This script accepts no arguments.' >&2; exit 1; }
[[ $(hostname) == ubuntu-infra ]] || { echo 'Unexpected host.' >&2; exit 1; }
command -v docker >/dev/null

helper=/usr/local/libexec/homelab-wait-lan-ip
dropin=/etc/systemd/system/docker.service.d/20-homelab-lan-ip.conf
helper_source="$REPO_ROOT/scripts/wait-lan-ip.sh"
dropin_source="$REPO_ROOT/systemd/docker.service.d/20-homelab-lan-ip.conf"
for directory in /usr/local/libexec /etc/systemd/system/docker.service.d; do
    [[ ! -L $directory ]] || { echo "Refusing symlink: $directory" >&2; exit 1; }
done
for pair in "$helper_source:$helper" "$dropin_source:$dropin"; do
    source_file=${pair%%:*}
    destination=${pair#*:}
    [[ ! -L $destination ]] || { echo "Refusing symlink: $destination" >&2; exit 1; }
    if [[ -e $destination ]] && ! cmp -s "$source_file" "$destination"; then
        echo "Existing different file: $destination; refusing overwrite." >&2
        exit 1
    fi
done
# Check the current address before installing anything.
bash "$helper_source" 192.168.0.8 5
install -d -o root -g root -m 0755 /usr/local/libexec /etc/systemd/system/docker.service.d
install -o root -g root -m 0755 "$helper_source" "$helper"
install -o root -g root -m 0644 "$dropin_source" "$dropin"
systemctl daemon-reload
systemctl show docker.service --property=ExecStartPre --value | grep -Fq "$helper" || {
    echo 'Docker did not load the IPv4 readiness guard.' >&2; exit 1;
}
echo 'Docker IPv4 readiness guard installed; existing networking settings preserved.'
