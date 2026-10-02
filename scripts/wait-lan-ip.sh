#!/bin/bash
# Docker ExecStartPre: require the exact IPv4 used by published ports.
set -Eeuo pipefail
[[ $# -le 2 ]] || { echo 'Usage: wait-lan-ip.sh [IPv4] [timeout-seconds]' >&2; exit 2; }
expected_ip=${1:-192.168.0.8}
wait_seconds=${2:-120}
[[ $expected_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $wait_seconds =~ ^[1-9][0-9]{0,3}$ ]] || {
    echo 'Expected an IPv4 address and a positive timeout (maximum 9999 seconds).' >&2
    exit 2
}
deadline=$((SECONDS + 10#$wait_seconds))
while ! /usr/sbin/ip -4 -o address show scope global | /usr/bin/awk -v expected="$expected_ip" '
    { split($4, address, "/"); if (address[1] == expected) found = 1 }
    END { exit !found }
'; do
    if (( SECONDS >= deadline )); then
        echo "LAN IPv4 $expected_ip unavailable; Docker startup deferred." >&2
        exit 1
    fi
    sleep 1
done
echo "LAN IPv4 $expected_ip is ready for Docker published ports."
