#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_docker
"${ML_COMPOSE[@]}" ps
"${MON_COMPOSE[@]}" ps

for service in postgres seaweedfs mlflow uptime-kuma; do
    if [[ $service == uptime-kuma ]]; then
        container=$("${MON_COMPOSE[@]}" ps -q "$service")
    else
        container=$("${ML_COMPOSE[@]}" ps -q "$service")
    fi
    [[ -n $container ]] || { echo "Missing running service: $service" >&2; exit 1; }
    health=$(docker inspect --format '{{.State.Health.Status}}' "$container")
    [[ $health == healthy ]] || { echo "$service: $health" >&2; exit 1; }
done

curl --fail --silent --show-error --max-time 10 http://192.168.0.8:5000/health >/dev/null
curl --fail --silent --show-error --max-time 10 http://192.168.0.8:5000/ >/dev/null
curl --fail --silent --show-error --max-time 10 http://192.168.0.8:3001/ >/dev/null
# Anonymous S3 must return exactly 403, not just any error or connection failure.
for path in / /mlflow-artifacts/; do
    status=$(curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' "http://192.168.0.8:8333$path")
    [[ $status == 403 ]] || { echo "Anonymous S3 access returned $status for $path (expected 403)." >&2; exit 1; }
done

# Inspect actual daemon bindings, including IPv6/wildcard mistakes.
all_ids=$("${ML_COMPOSE[@]}" ps -q)
all_ids+=$'\n'$("${MON_COMPOSE[@]}" ps -q)
mapfile -t containers <<< "$all_ids"
docker inspect "${containers[@]}" | python3 -c '
import json,sys
expected={"postgres":{},"seaweedfs":{"8333/tcp":"8333"},"mlflow":{"5000/tcp":"5000"},"uptime-kuma":{"3001/tcp":"3001"}}
for c in json.load(sys.stdin):
    service=c["Config"]["Labels"]["com.docker.compose.service"]
    bindings=c["HostConfig"]["PortBindings"] or {}
    assert set(bindings)==set(expected[service]), (service,bindings)
    for port,targets in bindings.items():
        assert targets==[{"HostIp":"192.168.0.8","HostPort":expected[service][port]}], (service,targets)
    assert not c["HostConfig"]["Privileged"], service
    assert c["HostConfig"]["NetworkMode"]!="host", service
    assert not any(m["Source"]=="/var/run/docker.sock" for m in c["Mounts"]), service
print("Actual published ports and container isolation: OK")
'
if timeout 2 bash -c 'exec 3<>/dev/tcp/192.168.0.8/5432' 2>/dev/null; then
    echo 'Unexpected listener on LAN port 5432.' >&2; exit 1
fi
echo 'All health, HTTP, anonymous S3 denial and PostgreSQL port checks passed.'
