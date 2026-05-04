#!/bin/bash
# Remove the route/pf state added by net-up.sh. Normally unnecessary; useful
# for troubleshooting.

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    log "Deleting route ${HPC4_IP} (${iface})"
    sudo_cmd route delete -host "$HPC4_IP" 2>/dev/null || warn "route delete failed"
else
    log "No HPC4 host route exists"
fi

log "Flushing pf anchor ${PF_ANCHOR}"
sudo_cmd pfctl -a "$PF_ANCHOR" -F rules 2>/dev/null || warn "pf flush failed or rules did not exist"

if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "Closing ControlMaster socket"
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
fi

ok "teardown complete"
