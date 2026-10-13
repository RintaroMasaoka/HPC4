#!/bin/bash
# Remove the host route installed by net-up.sh and close ControlMaster sockets.
# Usually unnecessary: rebooting the Mac clears host routes. Used for troubleshooting.
#
# Do not use sudo from AI execution. Only remove routes / pf state when the user
# runs net-down-local.sh in their own Terminal.

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "Deleting HPC4 host route (${iface})."
        sudo_cmd route -n delete -host "$HPC4_IP" 2>/dev/null || warn "Failed to delete route."
    else
        log "HPC4 host route is pinned to ${iface}. Deleting it requires sudo."
        log "Run the helper in a separate terminal:"
        log "    bash \"${SKILL_DIR}/scripts/net-down-local.sh\""
    fi
else
    log "No HPC4 host route exists."
fi

# Closing ControlMaster does not require sudo.
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "Closing ControlMaster socket."
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
    ok "ControlMaster socket closed."
fi
