#!/usr/bin/env bash
# Explicitly restarts the Docker daemon, verifies existing data, then reboots VM.
# Run in a separate terminal after the agent has recorded the test baseline.
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'This script accepts no arguments.' >&2; exit 1; }
[[ $(hostname) == ubuntu-infra ]] || { echo 'Unexpected host; refusing reboot.' >&2; exit 1; }
baseline="$REPO_ROOT/.runtime/restart-baseline.json"
[[ -f $baseline ]] || { echo 'Run the smoke test and record its baseline first.' >&2; exit 1; }
run_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$baseline")
[[ $run_id =~ ^[a-f0-9]{32}$ ]] || { echo 'Invalid baseline run ID.' >&2; exit 1; }
runuser -u mdy -- "$REPO_ROOT/scripts/healthcheck.sh"

before=$(systemctl show docker --property=ExecMainStartTimestampMonotonic --value)
systemctl restart docker
after=$(systemctl show docker --property=ExecMainStartTimestampMonotonic --value)
[[ $after -gt $before ]] || { echo 'Docker daemon restart was not observed.' >&2; exit 1; }
runuser -u mdy -- "$REPO_ROOT/scripts/wait-healthy.sh"
runuser -u mdy -- "$REPO_ROOT/scripts/smoke-test.sh" --verify "$run_id"
runuser -u mdy -- touch "$REPO_ROOT/.runtime/daemon-restart-passed"
echo 'Docker daemon automatic recovery and persistent SQL/S3 data: passed.'
echo 'Rebooting ubuntu-infra now. SSH/editor sessions will disconnect.'
echo 'Reconnect and tell the agent that the VM has rebooted.'
systemctl reboot
