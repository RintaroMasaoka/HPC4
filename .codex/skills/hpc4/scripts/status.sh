#!/bin/bash
# Print HPC4 connectivity state. Read-only; no sudo.

set -u
source "$(dirname "$0")/common.sh"

printf "## HPC4 connection status (%s)\n" "$(date '+%F %T')"

if [[ -f "$USER_CONF" ]] && [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    printf "  [ok]   user.conf.local loaded (HPC4_USER=%s, account=%s, partition=%s)\n" \
        "$HPC4_USER" "$HPC4_ACCOUNT" "$HPC4_PARTITION"
else
    printf "  [err]  user.conf.local missing. Create it with scripts/write-user-conf.sh <itso_username>\n"
fi

en0_gw="$(detect_en0_gw)"
ivanti_if="$(detect_ivanti_iface || true)"
hpc4_iface="$(current_hpc4_iface)"

printf "  -      en0 gateway: %s\n" "${en0_gw:-(none)}"
if [[ -n "$ivanti_if" ]]; then
    printf "  -      Ivanti VPN : %s (IP=%s)\n" "$ivanti_if" "$(ifconfig "$ivanti_if" | awk '/inet /{print $2; exit}')"
else
    printf "  -      Ivanti VPN : (not connected/detected)\n"
fi
printf "  -      HPC4 route : %s\n" "${hpc4_iface:-(not pinned)}"

if ping_ok 2; then
    printf "  [ok]   ping %s OK\n" "$HPC4_IP"
else
    printf "  [ng]   ping %s failed\n" "$HPC4_IP"
fi

if tcp22_ok; then
    printf "  [ok]   TCP/22 %s OK\n" "$HPC4_IP"
else
    printf "  [ng]   TCP/22 %s failed. Run net-up.sh outside the Codex sandbox.\n" "$HPC4_IP"
fi

if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    if ! tcp22_ok; then
        printf "  [skip] passwordless SSH unknown because TCP/22 is unreachable\n"
    elif ssh_passwordless_ok; then
        printf "  [ok]   passwordless SSH established\n"
    else
        printf "  [ng]   passwordless SSH not established; public key registration is needed\n"
    fi

    if cm_alive; then
        printf "  [ok]   ControlMaster socket alive\n"
    else
        printf "  -      ControlMaster not started (auto-starts on first ssh)\n"
    fi
fi
