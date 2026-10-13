#!/bin/bash
# Execute an arbitrary command on HPC4.
#   ./ssh-run.sh "<command>"
# Execute commands on HPC4 using an already configured connection.
# Requires passwordless SSH setup. ControlMaster makes subsequent calls immediate.

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

if [[ $# -lt 1 ]]; then
    err "Usage: ssh-run.sh \"<command to run on HPC4>\""
    exit 2
fi

# If networking is not ready, direct the user to the setup helper.
# Check reachability with TCP 22; eduroam may block ICMP.
# When the sandbox restricts route sockets, TCP probes may return false negatives.
# Attempt SSH directly without suggesting setup (successful SSH confirms
# actual reachability).
if ! tcp22_ok 3; then
    if route_probe_restricted; then
        log "Detected restricted route probes. Attempting SSH directly."
    else
        err "TCP 22 is unreachable. Run setup / recovery once in an interactive terminal:"
        err "  bash \"${SKILL_DIR}/scripts/setup-local.sh\""
        exit 3
    fi
fi

exec ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes hpc4 "$@"
