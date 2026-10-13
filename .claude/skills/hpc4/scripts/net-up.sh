#!/bin/bash
# Diagnose the route to HPC4 (143.89.184.3).
#
# Design:
#   - Do not use sudo from AI execution; delegate to the user.
#   - Allow sudo only when the user runs net-up-local.sh in their own Terminal.
#   - Route-change guidance is limited to the single HPC4 host route.
#   - Report a stale pin pointing outside HKUST separately from the absence
#     of any HKUST-capable interface (these formerly shared one error path).
#   - In the user's Terminal helper, if L3 is correct but L4 is blocked, flush
#     the pf main ruleset once and recheck. AI execution stops with helper guidance.
#
# Exit code:
#   0  Route OK and TCP 22 reachable.
#   1  No HKUST-capable interface (network connection must be fixed).
#   2  L3 route OK but TCP 22 unreachable (L4 block).
#   3  sudo operation required through the user's Terminal helper.
#   4  Route socket restricted by sandbox / permissions; result unknown.
#   5  Aborted a pin add/delete loop caused by disagreement between
#      find_hkust_iface and iface_is_hkust_capable.

set -u
source "$(dirname "$0")/common.sh"

# --- (-1) Recursion-depth guard --------------------------------------------
# net-up.sh restarts itself with exec bash "$0" after deleting a stale pin,
# adding a pin, or flushing pf main rules. Disagreeing checks can loop forever
# and repeatedly prompt for sudo. Carry depth in an environment variable to stop.
HPC4_NET_UP_DEPTH="${HPC4_NET_UP_DEPTH:-0}"
HPC4_NET_UP_DEPTH=$((HPC4_NET_UP_DEPTH + 1))
export HPC4_NET_UP_DEPTH
if (( HPC4_NET_UP_DEPTH > 4 )); then
    err "net-up.sh has retried ${HPC4_NET_UP_DEPTH} times (host pin add/delete loop)."
    err "find_hkust_iface() and iface_is_hkust_capable() likely disagree."
    err ""
    err "Current state:"
    err "  find_hkust_iface     : $(find_hkust_iface)"
    err "  current_hpc4_iface   : $(current_hpc4_iface)"
    err "  en0 IPv4             : $(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')"
    err "  default route        : $(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF, "via", $2; exit}')"
    err ""
    err "Workaround: remove the host pin once with bash \"${SKILL_DIR}/scripts/net-down.sh\","
    err "            then check your network (HKUST eduroam / Ivanti connection)."
    exit 5
fi

# --- (0a) Proactively flush VPN-client kill-switch rules ---------------------
# Some VPN clients install `block drop all` kill-switch rules in the pf main
# ruleset at connection time. These are evaluated before com.apple/* anchors,
# so an anchor's `pass quick` cannot bypass them. The previous com.apple/hpc4
# anchor strategy was removed; the remedy is flushing the main ruleset.
# VPN tunnels and Claude traffic routes remain in the kernel routing table.
# VPN reconnect / pause-resume may reinstall the rules. Run net-up-local.sh
# again when that happens to flush them again.
#
# Skip during AI execution (no sudo); the later L4-block branch provides
# helper guidance. Proactive flushing runs only in the user's Terminal helper.
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
    if sudo -n pfctl -s rules 2>/dev/null | grep -Eq '^block[[:space:]]+(drop|return)?([[:space:]]+quick)?[[:space:]]+(all|in|out)'; then
        log "Detected a kill switch (block drop all) in the pf main ruleset. Flushing rules."
        if sudo_cmd pfctl -F rules >/dev/null; then
            ok "Flushed pf main rules (VPN tunnel and Claude traffic routes are intact)."
            export HPC4_PF_FLUSH_ATTEMPTED=1
        else
            err "Could not flush pf main rules automatically. Rerun net-up-local.sh in an interactive terminal where sudo authentication can complete."
            exit 2
        fi
    fi
fi

# --- (0) TCP fast path: if TCP 22 is reachable, skip routing diagnostics ------
# Even configurations difficult to detect from interfaces (eduroam NAT 10.79/16
# plus another VPN) need no further diagnostics if HPC4 is actually reachable.
if tcp22_ok 3; then
    ok "TCP 22 reachable (skipping routing checks)."
    exit 0
fi

# --- (0.5) Sandbox / permissions: check route-socket restrictions ------------
# In AI sandboxes / environments with permission restrictions, route get / ping /
# some TCP probes return false negatives, misdiagnosing reachable HPC4 as a missing route.
# Suggesting sudo route add here would (a) fail due to permissions and
# (b) request an unnecessary route change. Exit immediately with unknown status.
if route_probe_restricted; then
    err "Route-socket access is restricted (typical of AI sandboxes / permission restrictions)."
    err "route get / ping / some TCP probes may return false negatives in this environment."
    err "Routing cannot be diagnosed reliably. HPC4 may actually be reachable."
    err ""
    err "  -> Rerun the same script in a separate terminal without permission restrictions."
    err "     No sudo route add is recommended while the result is unknown."
    exit 4
fi

# --- (1) Check HKUST capability --------------------------------------------
# (a) An interface with a direct 143.89/16 address.
# (b) An existing 143.89.x route through eduroam NAT (10.79/16).
# (c) route get returns a physical interface with a private IP (no other VPN owns default).
# (d) A physical interface with a 10.79/16 address (HKUST eduroam NAT).
hkust_iface="$(find_hkust_iface)"

if [[ -z "$hkust_iface" ]]; then
    err "Your Mac has no interface capable of reaching HKUST."
    err "  -> On campus: connect to HKUST campus eduroam (10.79/16 NAT) or HKUST wired networking."
    err "  -> Off campus: connect with Ivanti Secure Access (HKUST SSL VPN)."
    err ""
    err "Note: eduroam is federated and shares its SSID outside HKUST (HKSTP facilities such as"
    err "      DT Hub, other universities, airports). Those networks do not provide HKUST access."
    err "      See .claude/skills/hpc4/policy.md for details."
    exit 1
fi

# --- (2) Detect stale pins --------------------------------------------------
# A host pin pointing to a non-HKUST interface overrides the natural route.
# Ask the user to delete it.
existing_pin="$(current_hpc4_iface)"

if [[ -n "$existing_pin" ]] && ! iface_is_hkust_capable "$existing_pin"; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "Deleting stale HPC4 host route (${existing_pin})."
        sudo_cmd route -n delete -host "$HPC4_IP" || exit $?
        ok "Deleted stale route. Checking again."
        exec bash "$0"
    fi
    err "The previous HPC4 host route still points to ${existing_pin} (outside HKUST)."
    err "Deleting it requires sudo. Run the helper in a separate terminal:"
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
    exit 3
fi

# --- (3) Check whether the natural route goes through HKUST -----------------
# With no pin or a valid pin, the kernel should use the HKUST interface.
# If it selects a non-HKUST interface instead, a host pin is needed.
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"

if [[ -z "$egress" ]] || ! iface_is_hkust_capable "$egress"; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "Pinning the HPC4 host route to ${hkust_iface}."
        hpc4_pin_route "$hkust_iface" || exit $?
        ok "Added host route. Checking again."
        exec bash "$0"
    fi
    err "HKUST-capable interface (${hkust_iface}) exists, but the kernel routes HPC4 through another interface (${egress:-none})."
    err "Pinning the host route requires sudo. Run the helper in a separate terminal:"
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
    exit 3
fi

# --- (4) Route OK: test TCP 22 ---------------------------------------------
if [[ -n "$existing_pin" ]]; then
    ok "HPC4 route OK: via ${egress} (host pin present)."
else
    ok "HPC4 route OK: via ${egress} (kernel longest-prefix match)."
fi

if tcp22_ok 5; then
    ok "TCP 22 reachable."
    exit 0
fi

# --- (5) L4 blocked --------------------------------------------------------
# TCP 22 is unreachable despite egress through an HKUST-capable interface.
# In the user's Terminal helper, HKUST capability and correct L3 routing are
# established: treat a pf main-ruleset kill switch as most likely, flush once, and recheck.
# AI execution cannot handle sudo prompts; stop with helper guidance instead.
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" && "${HPC4_PF_FLUSH_ATTEMPTED:-0}" != "1" ]]; then
    log "L3 routing via ${egress} is correct. Flushing pf main rules and rechecking TCP 22."
    if sudo_cmd pfctl -F rules >/dev/null; then
        ok "Flushed pf main rules. Checking again."
        export HPC4_PF_FLUSH_ATTEMPTED=1
        exec bash "$0"
    fi
    err "Could not flush pf main rules automatically. Rerun net-up-local.sh in an interactive terminal where sudo authentication can complete."
    exit 2
fi

if [[ "${HPC4_PF_FLUSH_ATTEMPTED:-0}" == "1" ]]; then
    err "Flushed the pf main ruleset, but TCP 22 is still unreachable."
    err "L3 routing via ${egress} is correct; remaining candidates are other L4 filters / the VPN tunnel."
    err ""
    err "Possible causes:"
    err ""
    err "  B. System-enforced tunnel via NEPacketTunnelProvider (\`includeAllNetworks=true\`)."
    err "     -> Cannot override from user space. Check the relevant VPN client's settings."
    err ""
    err "  C. HKUST tunnel (Ivanti) authentication / reconnection is incomplete."
    err "     -> Check Ivanti Secure Access connection status and complete authentication."
    exit 2
fi

err "L3 routing via ${egress} is correct, but TCP 22 is unreachable. L4 (firewall / packet filter) is blocked."
err ""
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
    err "net-up-local.sh normally flushes pf main rules automatically, but could not complete it in this run."
    err "Rerun net-up-local.sh in an interactive terminal where sudo authentication can complete."
else
    err "AI execution cannot handle sudo prompts. Run the helper in a separate terminal:"
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
fi
exit 2
