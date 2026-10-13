#!/bin/bash
# Show HPC4 connection status with English messages readable directly in a terminal.
# Users should be able to choose their next action even when Codex is unavailable.
#
# Check order (report the most useful diagnostic information first):
#   1. user.conf.local
#   2. HKUST capability (does an interface have a 143.89/16 address?).
#   3. Stale HPC4 host pin.
#   4. Current HPC4 egress through an HKUST-capable interface.
#   5. TCP 22 reachability.
#   6. passwordless SSH / ControlMaster

set -u
source "$(dirname "$0")/common.sh"

LOCAL_HELPER_STATE="${SKILL_DIR}/setup-local.state.local"

state_value() {
    local key="$1"
    [[ -f "$LOCAL_HELPER_STATE" ]] || return 1
    awk -F= -v key="$key" '
        $1 == key {
            value = substr($0, length(key) + 2)
            if (value ~ /^"/ && value ~ /"$/) {
                value = substr(value, 2, length(value) - 2)
                gsub(/\\"/, "\"", value)
                gsub(/\\\\/, "\\", value)
            }
            print value
            exit
        }
    ' "$LOCAL_HELPER_STATE"
}

printf "## HPC4 connection status (%s)\n" "$(date '+%F %T')"

# In the Codex sandbox / without escalation, route-socket / ICMP / TCP probes
# may all return false negatives. When this flag is set, show route failures
# as [?] (sandbox restricted), rather than [ng], to avoid suggesting an
# unnecessary sudo route add.
restricted=0
if route_probe_restricted; then
    restricted=1
fi

# --- (1) Personal configuration --------------------------------------------
if [[ -f "$USER_CONF" ]] && [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    printf "  [ok]   user.conf.local loaded (HPC4_USER=%s, account=%s, partition=%s)\n" \
        "$HPC4_USER" "$HPC4_ACCOUNT" "$HPC4_PARTITION"
else
    printf "  [err]  user.conf.local is missing. Run bash \"%s/scripts/write-user-conf.sh\" <itso_username>\n" "$SKILL_DIR"
fi

if (( restricted )); then
    printf "  [?]    Route-socket access is restricted (Codex sandbox / execution without escalation).\n"
    printf "         Route / reachability / SSH checks may return false negatives; shown as [?].\n"
    printf "         HPC4 may actually be reachable. For a reliable check, use a separate terminal:\n"
fi

# --- (2) HKUST capability (independent of routing) --------------------------
hkust_iface="$(find_hkust_iface)"

if [[ -z "$hkust_iface" ]]; then
    printf "  [ng]   No HKUST reachability: no HKUST-capable interface found.\n"
    printf "         -> On campus: connect to HKUST campus eduroam (10.79/16 NAT) or HKUST wired networking.\n"
    printf "         -> Off campus: connect with Ivanti Secure Access (HKUST SSL VPN).\n"
    printf "         Note: eduroam is federated and works outside HKUST (e.g. DT Hub),\n"
    printf "               but those networks do not provide HKUST access. See .codex/skills/hpc4/policy.md\n"
    exit 0
fi

hkust_ip="$(ifconfig "$hkust_iface" 2>/dev/null | awk '/inet (143\.89\.|10\.79\.)/{print $2; exit}')"
printf "  [ok]   HKUST-capable interface: %s (IP=%s)\n" "$hkust_iface" "${hkust_ip:-?}"

# --- (3) Detect stale pins --------------------------------------------------
existing_pin="$(current_hpc4_iface)"

if [[ -n "$existing_pin" ]] && ! iface_is_hkust_capable "$existing_pin"; then
    printf "  [ng]   HPC4 host route: pinned to %s outside HKUST (stale pin).\n" "$existing_pin"
    printf "         This pin overrides the natural route through longest-prefix matching.\n"
    printf "         -> Run bash \"%s/scripts/setup-local.sh\" in a separate terminal.\n" "$SKILL_DIR"
    exit 0
fi

# --- (4) Current egress -----------------------------------------------------
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"

if [[ -z "$egress" ]] || ! iface_is_hkust_capable "$egress"; then
    if (( restricted )); then
        printf "  [?]    HPC4 egress: unknown (route-socket access restricted).\n"
    else
        printf "  [ng]   HPC4 egress: %s (outside HKUST).\n" "${egress:-none}"
        printf "         HKUST-capable interface (%s) exists, but the kernel selects another interface.\n" "$hkust_iface"
        printf "         -> Run bash \"%s/scripts/setup-local.sh\" in a separate terminal.\n" "$SKILL_DIR"
        exit 0
    fi
elif [[ -n "$existing_pin" ]]; then
    printf "  [ok]   HPC4 route: via %s (host pin present).\n" "$egress"
else
    printf "  [ok]   HPC4 route: via %s (kernel longest-prefix match).\n" "$egress"
fi

# --- (5) Reachability -------------------------------------------------------
if tcp22_ok 5; then
    printf "  [ok]   TCP 22 reachable.\n"
elif (( restricted )); then
    printf "  [?]    TCP 22 reachability: unknown (sandbox may restrict probes).\n"
else
    printf "  [ng]   TCP 22 unreachable: L3 routing is OK, but L4 is blocked.\n"
    printf "         -> Run bash \"%s/scripts/setup-local.sh\" once in a separate terminal.\n" "$SKILL_DIR"
    exit 0
fi

# --- (6) Authentication ----------------------------------------------------
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    if ssh_passwordless_ok; then
        printf "  [ok]   Passwordless SSH is ready.\n"
    elif (( restricted )); then
        printf "  [?]    Passwordless SSH: unknown (sandbox may restrict BatchMode SSH).\n"
    else
        printf "  [ng]   Passwordless SSH is not ready (key not in SSH agent or public key not registered).\n"
        helper_at="$(state_value LAST_HELPER_AT || true)"
        helper_status="$(state_value LAST_HELPER_STATUS || true)"
        helper_stage="$(state_value LAST_HELPER_STAGE || true)"
        helper_log="$(state_value LAST_HELPER_LOG || true)"
        if [[ -n "$helper_at" ]]; then
            printf "         -> Last setup-local.sh run: %s (status=%s, stage=%s)\n" "$helper_at" "${helper_status:-?}" "${helper_stage:-?}"
            printf "         -> Check the log before rerunning: %s\n" "${helper_log:-${SKILL_DIR}/setup-local.log}"
        else
            printf "         -> Run bash \"%s/scripts/setup-local.sh\" for network + SSH setup in one terminal.\n" "$SKILL_DIR"
        fi
    fi

    if cm_alive; then
        printf "  [ok]   ControlMaster socket is alive.\n"
    else
        printf "  -      ControlMaster is not running (starts automatically on the first SSH connection).\n"
    fi
fi
