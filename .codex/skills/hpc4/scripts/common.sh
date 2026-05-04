#!/bin/bash
# Shared constants and helpers. Sourced by the other scripts.

set -u

# --- Group-wide fixed parameters --------------------------------------------
HPC4_HOST="hpc4.ust.hk"
HPC4_IP="143.89.184.3"

# macOS /etc/pf.conf evaluates anchors under com.apple/* by default.
PF_ANCHOR="com.apple/hpc4"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${SKILL_DIR}/ssh_config"
USER_CONF="${SKILL_DIR}/user.conf.local"

# --- Load personal config ---------------------------------------------------
if [[ -f "$USER_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONF"
fi

: "${HPC4_ACCOUNT:=watanabemc}"
: "${HPC4_PARTITION:=amd}"
: "${HPC4_IDENTITY_FILE:=}"

require_user_conf() {
    if [[ -z "${HPC4_USER:-}" ]]; then
        printf "[hpc4][err] %s\n" "Personal config ${USER_CONF} not found. Run setup and create user.conf.local." >&2
        exit 1
    fi
}

# --- Logging ----------------------------------------------------------------
log()  { printf "[hpc4] %s\n" "$*"; }
ok()   { printf "[hpc4][ok] %s\n" "$*"; }
warn() { printf "[hpc4][warn] %s\n" "$*" >&2; }
err()  { printf "[hpc4][err] %s\n" "$*" >&2; }

# Run sudo commands without hanging in Codex.
#
# Default mode is AI-safe: never attempt sudo from Codex, even with sudo -n.
# The sudo timestamp cache may be scoped to a different terminal/session, so
# relying on it from Codex is brittle. Local admin approval belongs to the
# user-terminal helper only.
sudo_cmd() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
        return $?
    fi

    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" && -t 0 && -t 1 ]]; then
        sudo "$@"
        return $?
    fi

    err "sudo is required for this local route/pf change, and Codex must not wait for an interactive password prompt."
    err "Run this helper once in your own Terminal, then retry from Codex:"
    err "  bash \"${HPC4_LOCAL_HELPER:-${SKILL_DIR}/scripts/net-up-local.sh}\""
    return 20
}

# --- Network state detection -------------------------------------------------

detect_en0_gw() {
    netstat -rn 2>/dev/null | awk '$1=="default" && $NF=="en0" {print $2; exit}'
}

detect_ivanti_iface() {
    local i
    for i in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
        if ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | grep -q '^143\.89\.'; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

current_hpc4_iface() {
    netstat -rn 2>/dev/null | awk -v ip="$HPC4_IP" '$1==ip {print $NF; exit}'
}

iface_ipv4() {
    [[ -n "${1:-}" ]] || return 1
    ifconfig "$1" 2>/dev/null | awk '/inet /{print $2; exit}'
}

hpc4_bind_addr() {
    local iface
    iface="$(current_hpc4_iface)"
    [[ -n "$iface" ]] || return 1
    iface_ipv4 "$iface"
}

ping_ok() {
    local t="${1:-2}"
    ping -c 2 -W "${t}000" "$HPC4_IP" >/dev/null 2>&1
}

tcp22_ok() {
    local t="${1:-5}" bind_addr
    bind_addr="$(hpc4_bind_addr || true)"
    if command -v nc >/dev/null 2>&1; then
        if [[ -n "$bind_addr" ]]; then
            nc -s "$bind_addr" -z -G "$t" "$HPC4_IP" 22 >/dev/null 2>&1
        else
            nc -z -G "$t" "$HPC4_IP" 22 >/dev/null 2>&1
        fi
        return $?
    fi
    ( exec 3<>/dev/tcp/"$HPC4_IP"/22 ) >/dev/null 2>&1
}

fullvpn_default_route() {
    local iface addr
    iface="$(netstat -rn 2>/dev/null \
        | awk '$1=="default" && ($NF ~ /^utun/ || $NF ~ /^ppp/ || $NF ~ /^tap/ || $NF ~ /^wg/) {print $NF; exit}')"
    [[ -z "$iface" ]] && return 1

    addr="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}')"
    if [[ -n "$addr" && "$addr" =~ ^143\.89\. ]]; then
        return 1
    fi

    echo "$iface"
    return 0
}

# --- SSH-wrapper helpers ----------------------------------------------------
# macOS stock bash is 3.2, so avoid mapfile and nameref.

build_ssh_opts() {
    local bind_addr
    HPC4_SSH_OPTS=(-F "$SSH_CONFIG")
    if [[ -n "${HPC4_USER:-}" ]]; then
        HPC4_SSH_OPTS+=(-l "$HPC4_USER")
    fi
    if [[ -n "${HPC4_IDENTITY_FILE:-}" ]]; then
        HPC4_SSH_OPTS+=(-i "$HPC4_IDENTITY_FILE" -o IdentitiesOnly=yes)
    fi
    bind_addr="$(hpc4_bind_addr || true)"
    if [[ -n "$bind_addr" ]]; then
        HPC4_SSH_OPTS+=(-o "BindAddress=${bind_addr}")
    fi
}
build_ssh_opts

cm_alive() {
    require_user_conf
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O check hpc4 2>/dev/null
}

ssh_passwordless_ok() {
    require_user_conf
    ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 hpc4 true 2>/dev/null
}
