#!/bin/bash
# Prepare the network layer for HPC4 (143.89.184.3).

set -u
source "$(dirname "$0")/common.sh"

# (1) If SSH is already reachable, do nothing. ICMP alone is not enough:
# full-VPN kill switches can allow ping while blocking TCP/22.
if tcp22_ok; then
    iface="$(current_hpc4_iface)"
    ok "HPC4 SSH already reachable (via ${iface:-default route})"
    exit 0
fi

# (2) Detect a route candidate.
EN0_GW="$(detect_en0_gw)"
IVANTI_IF="$(detect_ivanti_iface || true)"
log "Detected:"
log "  en0 gateway : ${EN0_GW:-(none)}"
log "  Ivanti utun : ${IVANTI_IF:-(none)}"

MODE=""
if [[ -n "$IVANTI_IF" ]]; then
    MODE="ivanti"
elif [[ -n "$EN0_GW" ]]; then
    MODE="en0"
else
    err "No route candidate for HPC4."
    err "  - On campus: connect to eduroam or HKUST wired network"
    err "  - Off campus: start HKUST VPN (Ivanti Secure Access)"
    exit 1
fi
log "Route mode: $MODE"

# (3) Pin the host route.
if [[ "$MODE" == "en0" ]]; then
    if netstat -rn 2>/dev/null | grep -E "^${HPC4_IP}[[:space:]]" | grep -q "en0"; then
        ok "Route ${HPC4_IP} -> en0 already set"
    else
        log "sudo route add -host ${HPC4_IP} ${EN0_GW}"
        sudo_cmd route add -host "$HPC4_IP" "$EN0_GW" || { err "route add failed"; exit $?; }
        ok "Route added"
    fi
else
    if [[ "$(current_hpc4_iface)" == "$IVANTI_IF" ]]; then
        ok "Route ${HPC4_IP} -> ${IVANTI_IF} already set"
    else
        sudo_cmd route delete -host "$HPC4_IP" 2>/dev/null || true
        log "sudo route add -host ${HPC4_IP} -interface ${IVANTI_IF}"
        sudo_cmd route add -host "$HPC4_IP" -interface "$IVANTI_IF" || { err "route add failed"; exit $?; }
        ok "Route added via Ivanti"
    fi
fi

if tcp22_ok; then
    ok "HPC4 SSH reachable (via $(current_hpc4_iface))"
    exit 0
fi

# (4) If a full-tunnel VPN owns the default route, add a narrow pf exception.
vpn_if="$(fullvpn_default_route || true)"
if [[ -n "$vpn_if" ]]; then
    warn "Default route appears to be owned by ${vpn_if}; a full-tunnel VPN kill switch may be blocking HPC4."
    warn "Applying a narrow pf anchor exception for HPC4 only (mode=${MODE})."

    pf_rules="$(mktemp "${TMPDIR:-/tmp}/hpc4_pf.XXXXXX")" || { err "could not create pf rules temp file"; exit 1; }
    if [[ "$MODE" == "en0" ]]; then
        cat >"$pf_rules" <<EOF
pass out quick on en0 inet proto tcp from any to ${HPC4_IP} flags any keep state
pass out quick on en0 inet proto icmp from any to ${HPC4_IP} keep state
EOF
    else
        cat >"$pf_rules" <<EOF
pass out quick on ${IVANTI_IF} inet from any to ${HPC4_IP} flags any keep state
pass in  quick on ${IVANTI_IF} inet from ${HPC4_IP} to any flags any keep state
EOF
    fi

    sudo_cmd pfctl -a "$PF_ANCHOR" -f "$pf_rules" || { rc=$?; rm -f "$pf_rules"; err "pf anchor apply failed"; exit "$rc"; }
    rm -f "$pf_rules"
    ok "pf anchor ${PF_ANCHOR} applied"
else
    warn "TCP/22 is still unreachable, and no full-tunnel VPN default route was detected."
    warn "Possible causes: local firewall product, network outage, or VPN authentication not complete."
fi

if tcp22_ok; then
    ok "HPC4 SSH reachable (via $(current_hpc4_iface))"
    exit 0
fi

err "HPC4 is still unreachable after route/pf setup."
err "The host route is pinned, so the remaining causes are outside this script:"
err "  - the current en0 network does not actually reach HPC4"
err "  - a full VPN / Network Extension kill switch is blocking traffic below or before pf"
err "  - the VPN client needs a built-in split-tunnel / allowed-IP rule for ${HPC4_IP}"
err "Next practical steps:"
err "  - pause the full VPN temporarily, or add ${HPC4_IP} to its bypass / split-tunnel list"
err "  - if off campus, connect HKUST Ivanti Secure Access and rerun net-up-local.sh"
err "  - for local pf inspection: sudo pfctl -a ${PF_ANCHOR} -sr"
exit 2
