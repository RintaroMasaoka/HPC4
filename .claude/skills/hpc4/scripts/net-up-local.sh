#!/bin/bash
# user の Terminal 専用 entry point。
#
# Claude/Codex 等の AI 実行からは sudo password / Touch ID を扱わない。
# route / pf 変更や SSH key passphrase が必要な時だけ、この wrapper を
# user が自分の Terminal で実行する。

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
        err "HPC4_IDENTITY_FILE が設定されていますが、秘密鍵が見つかりません: ${configured}"
        return 2
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        err "HPC4_IDENTITY_FILE が未設定です。対話ターミナルで鍵を選択してから再実行してください。"
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
        err "HPC4_IDENTITY_FILE が未設定で、~/.ssh/ に候補鍵が見つかりません。"
        err "使用する秘密鍵を user.conf.local の HPC4_IDENTITY_FILE に設定するか、新しい鍵を作成してください。"
        return 2
    fi

    log "HPC4_IDENTITY_FILE が未設定です。使用する SSH 秘密鍵を選択してください:"
    i=1
    for candidate in "${identity_candidates[@]}"; do
        printf "  %d) %s" "$i" "$(display_path "$candidate")"
        [[ -f "${candidate}.pub" ]] || printf "  （対応する .pub なし）"
        printf "\n"
        i=$((i + 1))
    done
    printf "  q) キャンセル\n"

    while :; do
        printf "[hpc4] 鍵番号: "
        IFS= read -r choice
        case "$choice" in
            q|Q) return 2 ;;
            ''|*[!0-9]*) warn "番号を入力してください。" ;;
            *)
                if (( choice >= 1 && choice <= ${#identity_candidates[@]} )); then
                    selected="${identity_candidates[$((choice - 1))]}"
                    break
                fi
                warn "範囲外の番号です。"
                ;;
        esac
    done

    printf "[hpc4] この鍵を HPC4_IDENTITY_FILE に保存しますか？ [Y/n] "
    IFS= read -r persist
    case "$persist" in
        n|N)
            ;;
        *)
            if save_identity_file "$selected"; then
                ok "HPC4_IDENTITY_FILE を保存しました: $(display_path "$selected")"
            else
                warn "HPC4_IDENTITY_FILE の保存に失敗しました。この実行では選択した鍵を使います。"
            fi
            ;;
    esac

    HPC4_SELECTED_IDENTITY_FILE="$selected"
}

prepare_passwordless_ssh() {
    if [[ -z "${HPC4_USER:-}" ]] || [[ "$HPC4_USER" == "your_itso_username" ]]; then
        log "user.conf.local が未設定のため、SSH 認証準備はスキップします。"
        return 0
    fi

    if ssh_passwordless_ok; then
        ok "passwordless SSH 成立"
        return 0
    fi

    choose_identity_file || return $?
    local identity_file="$HPC4_SELECTED_IDENTITY_FILE"

    if [[ -f "$identity_file" ]]; then
        log "passwordless SSH 未成立。SSH agent に鍵を追加します（passphrase が必要な場合があります）"
        if ssh-add "$identity_file"; then
            HPC4_IDENTITY_FILE="$identity_file"
            build_ssh_opts
            if ssh_passwordless_ok; then
                ok "passwordless SSH 成立（ssh-add 後）"
                return 0
            fi
        else
            err "ssh-add に失敗しました。passphrase 入力を完了してから再実行してください。"
            return 2
        fi
    else
        warn "SSH 秘密鍵が見つかりません: ${identity_file}"
    fi

    err "passwordless SSH がまだ成立していません。公開鍵登録が必要な可能性があります。"
    if [[ -f "${identity_file}.pub" ]]; then
        local pub_q
        printf -v pub_q '%q' "${identity_file}.pub"
        err "公開鍵未登録なら、別ターミナルで一度だけ実行してください:"
        err "  ssh-copy-id -i ${pub_q} ${HPC4_USER}@${HPC4_HOST}"
    else
        err "選択した秘密鍵に対応する公開鍵がありません: $(display_path "${identity_file}.pub")"
        err "公開鍵を作成してから ssh-copy-id してください。"
    fi
    return 2
}

if [[ "$(id -u)" -ne 0 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf "[hpc4][err] net-up-local.sh は sudo 認証や SSH key passphrase を扱うため、対話ターミナルから実行してください。\n" >&2
        exit 2
    fi

    printf "[hpc4] sudo 認証を確認します（password / Touch ID が必要な場合があります）\n"
    if ! sudo -v; then
        printf "[hpc4][err] sudo 認証に失敗しました。認証を完了してから再実行してください。\n" >&2
        exit 2
    fi
fi

export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/net-up-local.sh"
bash "${SCRIPT_DIR}/net-up.sh" || exit $?
prepare_passwordless_ssh
