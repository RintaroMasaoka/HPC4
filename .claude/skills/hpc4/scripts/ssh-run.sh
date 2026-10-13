#!/bin/bash
# Execute an arbitrary command on HPC4.
#   ./ssh-run.sh "<command>"
# If routing is not ready, call net-up.sh to pin the HPC4 host route.
# Requires passwordless SSH setup. ControlMaster makes subsequent calls immediate.

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

if [[ $# -lt 1 ]]; then
    err "Usage: ssh-run.sh \"<command to run on HPC4>\""
    exit 2
fi

# Prepare networking if needed (skip if HPC4 is already reachable).
# Check reachability with TCP 22; eduroam may block ICMP.
# When the sandbox restricts route sockets, TCP probes may return false negatives.
# Attempt SSH directly without net-up.sh (successful SSH confirms
# actual reachability).
if ! tcp22_ok 3; then
    if route_probe_restricted; then
        log "Detected restricted route probes. Skipping net-up.sh and attempting SSH directly."
    else
        log "Routing is not ready. Running net-up.sh."
        bash "$(dirname "$0")/net-up.sh" || exit $?
    fi
fi

exec ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes hpc4 "$@"
