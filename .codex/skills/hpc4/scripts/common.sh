#!/bin/bash
# Shared constants and helpers, sourced by the other scripts.
#
# This skill manages only the host route to HPC4 (143.89.184.3).
# Never touch the default route or Codex traffic: users must be able to ask for help.
# Do not identify VPN products. Check whether the kernel routing table has
# an interface with a 143.89/16 address; that is the only criterion.

set -u

# --- Fixed group-wide parameters -------------------------------------------
HPC4_HOST="hpc4.ust.hk"
HPC4_IP="143.89.184.3"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${SKILL_DIR}/ssh_config"
USER_CONF="${SKILL_DIR}/user.conf.local"

# --- Load personal configuration -------------------------------------------
if [[ -f "$USER_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONF"
fi

: "${HPC4_ACCOUNT:=watanabemc}"
: "${HPC4_PARTITION:=amd}"
: "${HPC4_IDENTITY_FILE:=}"

require_user_conf() {
    if [[ -z "${HPC4_USER:-}" ]]; then
        printf "[hpc4][err] %s\n" "Personal configuration ${USER_CONF} is missing. Run setup (scripts/write-user-conf.sh <itso_username>)." >&2
        exit 1
    fi
}

# --- Logging ---------------------------------------------------------------
log()  { printf "[hpc4] %s\n" "$*"; }
ok()   { printf "[hpc4][ok] %s\n" "$*"; }
warn() { printf "[hpc4][warn] %s\n" "$*" >&2; }
err()  { printf "[hpc4][err] %s\n" "$*" >&2; }

# Safely execute operations requiring sudo.
#
# Do not attempt sudo from Codex by default. Password / Touch ID prompts
# are handled only by the user's Terminal helper (setup-local.sh).
sudo_cmd() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
        return $?
    fi

    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" && -t 0 ]]; then
        local tmp status line
        tmp="$(mktemp -t hpc4-sudo.XXXXXX)" || {
            err "Could not create a temporary file for sudo."
            return 20
        }

        sudo "$@" 2>"$tmp"
        status=$?
        if (( status != 0 )); then
            err "sudo command failed (exit ${status}): sudo $*"
            while IFS= read -r line; do
                [[ -n "$line" ]] && err "  ${line}"
            done <"$tmp"
        fi
        rm -f "$tmp"
        return "$status"
    fi

    err "sudo is required, but Codex execution cannot handle sudo prompts."
    err "Run the following once in a separate terminal, then retry:"
    err "  bash \"${HPC4_LOCAL_HELPER:-${SKILL_DIR}/scripts/setup-local.sh}\""
    return 20
}

# --- HPC4 reachability checks ----------------------------------------------

# Ask the kernel for the HPC4 egress interface. Output: <iface> [<gateway>].
# Return only the interface for absent/link-local gateways; empty if unavailable.
hpc4_route_resolve() {
    route get "$HPC4_IP" 2>/dev/null | awk '
        /interface:/ {iface=$2}
        /gateway:/   {gw=$2}
        END {
            if (!iface) exit
            if (gw && gw !~ /^link#/) print iface, gw
            else                       print iface
        }
    '
}

# Does this interface have a 143.89/16 IPv4 address (HKUST network or tunnel)?
iface_has_hkust_ip() {
    [[ -n "${1:-}" ]] || return 1
    ifconfig "$1" 2>/dev/null | awk '/inet 143\.89\./{found=1} END{exit !found}'
}

# Can the given interface reach HKUST?
# (1) A direct 143.89/16 address (HKUST VPN / wired).
# (2) eduroam NAT: private IP and a 143.89.x host route through this interface.
# (3) A 10.79/16 address specific to HKUST eduroam.
iface_is_hkust_capable() {
    [[ -n "${1:-}" ]] || return 1
    ifconfig "$1" 2>/dev/null | awk '/inet 143\.89\./{found=1} END{exit !found}' && return 0
    ifconfig "$1" 2>/dev/null | grep -qE 'inet (10\.|192\.168\.)' || return 1
    netstat -rn 2>/dev/null | awk -v iface="$1" \
        '$NF==iface && /^143\.89\./{found=1} END{exit !found}' && return 0
    ifconfig "$1" 2>/dev/null | grep -q 'inet 10\.79\.'
}

# Scan all interfaces and return the first HKUST-capable interface, or empty.
# Determine HKUST reachability independently of the routing table.
# A stale host pin that distorts route get does not affect this check.
#
# Detection order:
#   (1) An interface with a direct 143.89/16 address (HKUST VPN / wired).
#   (2) A physical interface with an HKUST eduroam 10.79/16 address.
#   (3) A route for 143.89.x through a private gateway on a physical interface.
#       (eduroam NAT + existing host route); revalidate to avoid stale routes
#       with iface_is_hkust_capable.
#   (4) route get returns a physical interface passing iface_is_hkust_capable.
#       (When another VPN does not own the default route.)
#
# Paths 3/4 are heuristics: always confirm with iface_is_hkust_capable.
# Otherwise a stale netstat entry from a previous HKUST eduroam session,
# such as `143.89.x -> 10.79.255.254 -> en0`, can incorrectly classify en0
# on another network (e.g. 172.22/22) as HKUST-capable, causing network repair
# to add a pin, reject it on the next iface_is_hkust_capable check, delete it,
# and repeat indefinitely.
find_hkust_iface() {
    local iface
    iface=$(ifconfig 2>/dev/null | awk '
        /^[a-z]/ { iface=$1; sub(":", "", iface) }
        /inet 143\.89\./ { print iface; exit }
    ')
    [[ -n "$iface" ]] && { printf '%s' "$iface"; return 0; }

    iface=$(ifconfig 2>/dev/null | awk '
        /^en/ { iface=$1; sub(":", "", iface) }
        /inet 10\.79\./ { print iface; exit }
    ')
    [[ -n "$iface" ]] && { printf '%s' "$iface"; return 0; }

    iface=$(netstat -rn 2>/dev/null | awk '
        /^143\.89\./ &&
        ($2 ~ /^10\./ || $2 ~ /^192\.168\./) &&
        $NF ~ /^en/ { print $NF; exit }
    ')
    if [[ -n "$iface" ]] && iface_is_hkust_capable "$iface"; then
        printf '%s' "$iface"
        return 0
    fi

    local route_iface
    route_iface=$(route get "$HPC4_IP" 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$route_iface" ]] && [[ "$route_iface" =~ ^en ]] \
        && iface_is_hkust_capable "$route_iface"; then
        printf '%s' "$route_iface"
        return 0
    fi
}

# Interface of the existing HPC4 host route, or empty if absent.
current_hpc4_iface() {
    netstat -rn 2>/dev/null | awk -v ip="$HPC4_IP" '$1==ip {print $NF; exit}'
}

# First IPv4 address of the given interface, or empty if absent.
iface_ipv4() {
    [[ -n "${1:-}" ]] || return 1
    ifconfig "$1" 2>/dev/null | awk '/inet /{print $2; exit}'
}

# IPv4 of the HPC4 pinned interface, used as BindAddress for nc / ssh.
# Prevent the kernel from selecting the wrong egress on multihomed Macs (en0 + utun).
# Return empty if no pin/interface exists; callers fall back without BindAddress.
hpc4_bind_addr() {
    local iface
    iface="$(current_hpc4_iface)"
    [[ -n "$iface" ]] || return 1
    iface_ipv4 "$iface"
}

# Default gateway of the given interface (DHCP / VPN), or empty if absent.
# Prefer netstat's per-interface default, then ipconfig's DHCP option.
default_gateway_for_iface() {
    [[ -n "${1:-}" ]] || return 1
    local gw
    gw="$(netstat -rn -f inet 2>/dev/null | awk -v iface="$1" '$1=="default" && $NF==iface {print $2; exit}')"
    if [[ -z "$gw" ]]; then
        gw="$(ipconfig getoption "$1" router 2>/dev/null)"
    fi
    [[ -n "$gw" ]] && printf '%s' "$gw"
}

hpc4_pin_route() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || return 1
    if ifconfig "$iface" 2>/dev/null | grep -q 'inet 143\.89\.'; then
        sudo_cmd route -n add -host "$HPC4_IP" -interface "$iface"
        return $?
    fi
    local gw
    gw="$(default_gateway_for_iface "$iface")"
    [[ -n "$gw" ]] || return 1
    sudo_cmd route -n add -host "$HPC4_IP" -gateway "$gw"
}

# Is TCP port 22 reachable? Timeout in seconds, default 5.
# macOS BSD nc: -G is the connect timeout; -w is the overall I/O timeout.
# If pinned, bind to that interface's IPv4 source address on multihomed Macs
# (en0 + utun), preventing probes from taking the VPN egress despite a pin.
# Without a pin, use normal source-address selection.
tcp22_ok() {
    local t="${1:-5}" bind_addr
    bind_addr="$(hpc4_bind_addr || true)"
    if [[ -n "$bind_addr" ]]; then
        nc -s "$bind_addr" -z -G "$t" -w "$t" "$HPC4_IP" 22 >/dev/null 2>&1
    else
        nc -z -G "$t" -w "$t" "$HPC4_IP" 22 >/dev/null 2>&1
    fi
}

# Ping reachability check. Timeout in seconds, default 2.
ping_ok() {
    local t="${1:-2}"
    ping -c 2 -W "${t}000" "$HPC4_IP" >/dev/null 2>&1
}

# Is route-socket access denied by permissions?
# In the Codex sandbox / without escalation, `route -n get`, `ping`, and
# some TCP probes return "Operation not permitted" despite real reachability.
# This helper catches the restriction before it is misdiagnosed as a missing route.
# If true, callers must not suggest route changes such as sudo route add.
route_probe_restricted() {
    local out
    out=$(route -n get "$HPC4_IP" 2>&1)
    case "$out" in
        *"Operation not permitted"*) return 0 ;;
        *"not permitted"*)           return 0 ;;
        *"Permission denied"*)       return 0 ;;
    esac
    return 1
}

# --- SSH wrapper helpers ---------------------------------------------------
# Avoid mapfile / nameref for compatibility with macOS Bash 3.2.

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
