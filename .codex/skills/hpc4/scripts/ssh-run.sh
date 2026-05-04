#!/bin/bash
# Run an arbitrary command on HPC4.
#   ./ssh-run.sh "<command>"
# Calls net-up.sh automatically if TCP/22 is not reachable.
# Auth is passwordless SSH (requires setup). ControlMaster keeps subsequent calls fast.

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

if [[ $# -lt 1 ]]; then
    err "Usage: ssh-run.sh \"<command to run on HPC4>\""
    exit 2
fi

# If the network layer is not yet ready, fix it. TCP/22 is the service we need;
# ICMP can be misleading under full-VPN kill switches.
if ! tcp22_ok; then
    log "SSH route not ready. Running net-up.sh"
    bash "$(dirname "$0")/net-up.sh" || exit $?
fi

exec ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes hpc4 "$@"
