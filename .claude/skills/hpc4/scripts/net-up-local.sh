#!/bin/bash
# Entry point for the user's own Terminal.
#
# AI execution (Claude / Codex) does not handle sudo password / Touch ID prompts.
# Use this wrapper for route / pf changes or SSH key passphrases;
# the user runs it in their own Terminal.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

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
    for existing in "${identity_candidates[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
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

    if [[ ! -t 0 || ! -t 1 ]]; then
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

prepare_passwordless_ssh() {
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
        local pub_q
        printf -v pub_q '%q' "${identity_file}.pub"
        err "If the public key is not registered, run this once in a separate terminal:"
        err "  ssh-copy-id -i ${pub_q} ${HPC4_USER}@${HPC4_HOST}"
    else
        err "No public key matches the selected private key: $(display_path "${identity_file}.pub")"
        err "Create the public key, then run ssh-copy-id."
    fi
    return 2
}

if [[ "$(id -u)" -ne 0 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf "[hpc4][err] Run net-up-local.sh in an interactive terminal to handle sudo authentication and SSH key passphrases.\n" >&2
        exit 2
    fi

    printf "[hpc4] Checking sudo authentication (password / Touch ID may be required).\n"
    if ! sudo -v; then
        printf "[hpc4][err] sudo authentication failed. Complete authentication, then retry.\n" >&2
        exit 2
    fi
fi

export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/net-up-local.sh"
bash "${SCRIPT_DIR}/net-up.sh" || exit $?
prepare_passwordless_ssh
