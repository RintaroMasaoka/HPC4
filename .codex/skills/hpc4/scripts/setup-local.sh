#!/bin/bash
# Setup entry point for the user's own Terminal.
#
# Codex execution does not handle sudo password / Touch ID prompts.
# For route / pf changes, SSH key passphrases, or HPC4 password + 2FA,
# the user runs this single wrapper in their own Terminal.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOCAL_HELPER_STATE="${SKILL_DIR}/setup-local.state.local"
LOCAL_HELPER_LOG="${SKILL_DIR}/setup-local.log"
HPC4_HELPER_STAGE="start"
declare -a identity_candidates

if [[ -t 0 && -t 1 ]]; then
    HPC4_HAS_INTERACTIVE_TTY=1
else
    HPC4_HAS_INTERACTIVE_TTY=0
fi

has_interactive_tty() {
    [[ "${HPC4_HAS_INTERACTIVE_TTY:-0}" == "1" && -t 0 ]]
}

quote_state_value() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_helper_state() {
    local status="${1:-running}" exit_code="${2:-}" tmp
    tmp="$(mktemp -t hpc4-helper-state.XXXXXX)" || return 0
    {
        printf 'LAST_HELPER_AT=%s\n' "$(quote_state_value "$(date '+%F %T')")"
        printf 'LAST_HELPER_STATUS=%s\n' "$(quote_state_value "$status")"
        printf 'LAST_HELPER_EXIT=%s\n' "$(quote_state_value "$exit_code")"
        printf 'LAST_HELPER_STAGE=%s\n' "$(quote_state_value "$HPC4_HELPER_STAGE")"
        printf 'LAST_HELPER_LOG=%s\n' "$(quote_state_value "$LOCAL_HELPER_LOG")"
    } >"$tmp" && mv "$tmp" "$LOCAL_HELPER_STATE"
    rm -f "$tmp" 2>/dev/null || true
}

finish_helper_state() {
    local status="$?"
    if (( status == 0 )); then
        write_helper_state "ok" "$status"
    else
        write_helper_state "err" "$status"
    fi
}

mkdir -p "$SKILL_DIR" 2>/dev/null || true
: >"$LOCAL_HELPER_LOG"
exec > >(tee -a "$LOCAL_HELPER_LOG") 2>&1
write_helper_state "running" ""
trap finish_helper_state EXIT

display_path() {
    local path="$1"
    case "$path" in
        "$HOME"/*) printf '~/%s' "${path#"$HOME"/}" ;;
        *) printf '%s' "$path" ;;
    esac
}

add_identity_candidate() {
    local candidate="$1" existing base
    [[ -f "$candidate" ]] || return 0
    base="$(basename "$candidate")"
    case "$base" in
        *.pub|authorized_keys|known_hosts|known_hosts.*|config|*.old|*.bak) return 0 ;;
    esac
    if (( ${#identity_candidates[@]} > 0 )); then
        for existing in "${identity_candidates[@]}"; do
            [[ "$existing" == "$candidate" ]] && return 0
        done
    fi
    identity_candidates+=("$candidate")
}

save_identity_file() {
    local identity_file="$1" escaped tmp
    [[ -f "$USER_CONF" ]] || return 0

    escaped="${identity_file//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    tmp="$(mktemp -t hpc4-user-conf.XXXXXX)" || return 1

    {
        while IFS= read -r line; do
            case "$line" in
                HPC4_IDENTITY_FILE=*) printf 'HPC4_IDENTITY_FILE="%s"\n' "$escaped" ;;
                *) printf '%s\n' "$line" ;;
            esac
        done <"$USER_CONF"
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }

    if ! grep -q '^HPC4_IDENTITY_FILE=' "$USER_CONF"; then
        printf 'HPC4_IDENTITY_FILE="%s"\n' "$escaped" >>"$tmp"
    fi

    mv "$tmp" "$USER_CONF"
}

choose_identity_file() {
    HPC4_HELPER_STAGE="choose_identity"
    HPC4_SELECTED_IDENTITY_FILE=""

    local configured="${HPC4_IDENTITY_FILE:-}" pub candidate i choice selected persist
    if [[ -n "$configured" ]]; then
        if [[ "$configured" == "~/"* ]]; then
            configured="${HOME}/${configured#~/}"
        fi
        if [[ -f "$configured" ]]; then
            HPC4_SELECTED_IDENTITY_FILE="$configured"
            return 0
        fi
        err "HPC4_IDENTITY_FILE is set, but the private key was not found: ${configured}"
        return 2
    fi

    if ! has_interactive_tty; then
        err "HPC4_IDENTITY_FILE is not set. Select a key in an interactive terminal, then retry."
        return 2
    fi

    identity_candidates=()
    for pub in "$HOME"/.ssh/*.pub; do
        [[ -f "$pub" ]] || continue
        add_identity_candidate "${pub%.pub}"
    done
    for candidate in "$HOME"/.ssh/id_* "$HOME"/.ssh/*.pem; do
        add_identity_candidate "$candidate"
    done

    if (( ${#identity_candidates[@]} == 0 )); then
        err "HPC4_IDENTITY_FILE is not set, and no candidate keys were found in ~/.ssh/."
        err "Set HPC4_IDENTITY_FILE in user.conf.local to your private key, or create a new key."
        return 2
    fi

    log "HPC4_IDENTITY_FILE is not set. Select the SSH private key to use:"
    i=1
    for candidate in "${identity_candidates[@]}"; do
        printf "  %d) %s" "$i" "$(display_path "$candidate")"
        [[ -f "${candidate}.pub" ]] || printf "  (no matching .pub file)"
        printf "\n"
        i=$((i + 1))
    done
    printf "  q) Cancel\n"

    while :; do
        printf "[hpc4] Key number: "
        IFS= read -r choice
        case "$choice" in
            q|Q) return 2 ;;
            ''|*[!0-9]*) warn "Enter a number." ;;
            *)
                if (( choice >= 1 && choice <= ${#identity_candidates[@]} )); then
                    selected="${identity_candidates[$((choice - 1))]}"
                    break
                fi
                warn "Number out of range."
                ;;
        esac
    done

    printf "[hpc4] Save this key as HPC4_IDENTITY_FILE? [Y/n] "
    IFS= read -r persist
    case "$persist" in
        n|N)
            ;;
        *)
            if save_identity_file "$selected"; then
                ok "Saved HPC4_IDENTITY_FILE: $(display_path "$selected")"
            else
                warn "Could not save HPC4_IDENTITY_FILE. Using the selected key for this run."
            fi
            ;;
    esac

    HPC4_SELECTED_IDENTITY_FILE="$selected"
}

repair_network() {
    HPC4_HELPER_STAGE="network_repair"

    HPC4_NET_UP_DEPTH="${HPC4_NET_UP_DEPTH:-0}"
    HPC4_NET_UP_DEPTH=$((HPC4_NET_UP_DEPTH + 1))
    export HPC4_NET_UP_DEPTH
    if (( HPC4_NET_UP_DEPTH > 4 )); then
        err "Network repair has retried ${HPC4_NET_UP_DEPTH} times (host pin add/delete loop)."
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
        return 5
    fi

    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        if sudo -n pfctl -s rules 2>/dev/null | grep -Eq '^block[[:space:]]+(drop|return)?([[:space:]]+quick)?[[:space:]]+(all|in|out)'; then
            log "Detected a kill switch (block drop all) in the pf main ruleset. Flushing rules."
            if sudo_cmd pfctl -F rules >/dev/null; then
                ok "Flushed pf main rules (VPN tunnel and Codex traffic routes are intact)."
                export HPC4_PF_FLUSH_ATTEMPTED=1
            else
                err "Could not flush pf main rules automatically. Rerun setup-local.sh in an interactive terminal where sudo authentication can complete."
                return 2
            fi
        fi
    fi

    if tcp22_ok 3; then
        ok "TCP 22 reachable (skipping routing checks)."
        return 0
    fi

    if route_probe_restricted; then
        err "Route-socket access is restricted (typical of the Codex sandbox / execution without escalation)."
        err "route get / ping / some TCP probes may return false negatives in this environment."
        err "Routing cannot be diagnosed reliably. HPC4 may actually be reachable."
        err ""
        err "  -> Rerun setup-local.sh in an interactive terminal without permission restrictions."
        err "     No sudo route add is recommended while the result is unknown."
        return 4
    fi

    local hkust_iface existing_pin resolve egress
    hkust_iface="$(find_hkust_iface)"

    if [[ -z "$hkust_iface" ]]; then
        err "Your Mac has no interface capable of reaching HKUST."
        err "  -> On campus: connect to HKUST campus eduroam (10.79/16 NAT) or HKUST wired networking."
        err "  -> Off campus: connect with Ivanti Secure Access (HKUST SSL VPN)."
        err ""
        err "Note: eduroam is federated and shares its SSID outside HKUST (HKSTP facilities such as"
        err "      DT Hub, other universities, airports). Those networks do not provide HKUST access."
        err "      See .codex/skills/hpc4/policy.md for details."
        return 1
    fi

    existing_pin="$(current_hpc4_iface)"

    if [[ -n "$existing_pin" ]] && ! iface_is_hkust_capable "$existing_pin"; then
        log "Deleting stale HPC4 host route (${existing_pin})."
        sudo_cmd route -n delete -host "$HPC4_IP" || return $?
        ok "Deleted stale route. Checking again."
        repair_network
        return $?
    fi

    resolve="$(hpc4_route_resolve)"
    egress="$(printf '%s' "$resolve" | awk '{print $1}')"

    if [[ -z "$egress" ]] || ! iface_is_hkust_capable "$egress"; then
        log "Pinning the HPC4 host route to ${hkust_iface}."
        hpc4_pin_route "$hkust_iface" || return $?
        ok "Added host route. Checking again."
        repair_network
        return $?
    fi

    if [[ -n "$existing_pin" ]]; then
        ok "HPC4 route OK: via ${egress} (host pin present)."
    else
        ok "HPC4 route OK: via ${egress} (kernel longest-prefix match)."
    fi

    if tcp22_ok 5; then
        ok "TCP 22 reachable."
        return 0
    fi

    if [[ "${HPC4_PF_FLUSH_ATTEMPTED:-0}" != "1" ]]; then
        log "L3 routing via ${egress} is correct. Flushing pf main rules and rechecking TCP 22."
        if sudo_cmd pfctl -F rules >/dev/null; then
            ok "Flushed pf main rules. Checking again."
            export HPC4_PF_FLUSH_ATTEMPTED=1
            repair_network
            return $?
        fi
        err "Could not flush pf main rules automatically. Rerun setup-local.sh in an interactive terminal where sudo authentication can complete."
        return 2
    fi

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
    return 2
}

prepare_passwordless_ssh() {
    HPC4_HELPER_STAGE="prepare_passwordless_ssh"
    if [[ -z "${HPC4_USER:-}" ]] || [[ "$HPC4_USER" == "your_itso_username" ]]; then
        log "user.conf.local is not configured. Skipping SSH authentication setup."
        return 0
    fi

    if ssh_passwordless_ok; then
        ok "Passwordless SSH is ready."
        return 0
    fi

    choose_identity_file || return $?
    local identity_file="$HPC4_SELECTED_IDENTITY_FILE"

    if [[ -f "$identity_file" ]]; then
        HPC4_HELPER_STAGE="ssh_add"
        log "Passwordless SSH is not ready. Adding the key to the SSH agent (a passphrase may be required)."
        if ssh-add "$identity_file"; then
            HPC4_IDENTITY_FILE="$identity_file"
            build_ssh_opts
            if ssh_passwordless_ok; then
                ok "Passwordless SSH is ready (after ssh-add)."
                return 0
            fi
        else
            err "ssh-add failed. Complete passphrase entry, then retry."
            return 2
        fi
    else
        warn "SSH private key not found: ${identity_file}"
    fi

    err "Passwordless SSH is still not ready. Public-key registration may be required."
    if [[ -f "${identity_file}.pub" ]]; then
        local pub_q answer bind_addr copy_id_args
        printf -v pub_q '%q' "${identity_file}.pub"
        if has_interactive_tty; then
            printf "[hpc4] Register the public key on HPC4 now? Password + 2FA required. [Y/n] "
            IFS= read -r answer
            case "$answer" in
                n|N)
                    err "Skipped public-key registration. If needed, run this in the same terminal:"
                    err "  ssh-copy-id -i ${pub_q} -F \"${SSH_CONFIG}\" ${HPC4_USER}@hpc4"
                    return 2
                    ;;
            esac

            HPC4_HELPER_STAGE="ssh_copy_id"
            copy_id_args=(-i "${identity_file}.pub" -F "$SSH_CONFIG")
            bind_addr="$(hpc4_bind_addr || true)"
            if [[ -n "$bind_addr" ]]; then
                copy_id_args+=(-o "BindAddress=${bind_addr}")
            fi

            log "Running ssh-copy-id. Enter your HPC4 password and complete 2FA."
            if ssh-copy-id "${copy_id_args[@]}" "${HPC4_USER}@hpc4"; then
                HPC4_IDENTITY_FILE="$identity_file"
                build_ssh_opts
                if ssh_passwordless_ok; then
                    ok "Passwordless SSH is ready (after ssh-copy-id)."
                    return 0
                fi
                err "ssh-copy-id completed, but the passwordless SSH recheck failed."
                return 2
            fi
            err "ssh-copy-id failed. Check your HPC4 password / 2FA and public-key registration."
        else
            err "If the public key is not registered, run this helper in an interactive terminal. For manual setup:"
            err "  ssh-copy-id -i ${pub_q} -F \"${SSH_CONFIG}\" ${HPC4_USER}@hpc4"
        fi
    else
        err "No public key matches the selected private key: $(display_path "${identity_file}.pub")"
        err "Create the public key, then run ssh-copy-id."
    fi
    return 2
}

if [[ "$(id -u)" -ne 0 ]]; then
    HPC4_HELPER_STAGE="sudo_auth"
    if ! has_interactive_tty; then
        printf "[hpc4][err] Run setup-local.sh in an interactive terminal to handle sudo authentication and SSH key passphrases.\n" >&2
        exit 2
    fi

    printf "[hpc4] Checking sudo authentication (password / Touch ID may be required).\n"
    if ! sudo -v; then
        printf "[hpc4][err] sudo authentication failed. Complete authentication, then retry.\n" >&2
        exit 2
    fi
fi

export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/setup-local.sh"
repair_network || exit $?
prepare_passwordless_ssh
