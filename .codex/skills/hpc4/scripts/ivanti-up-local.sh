#!/bin/bash
# user の Terminal 専用 Ivanti helper。
#
# Ivanti Secure Access を起動し、対象 connection の Connect ボタンを押す。
# password / 2FA / browser SSO は user が GUI で完了する前提で、認証情報は扱わない。
# HKUST IF が出たら既存の net-up.sh / net-up-local.sh に引き継ぐ。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

APP_PATH="${HPC4_IVANTI_APP_PATH:-/Applications/Ivanti Secure Access.app}"
WAIT_SECONDS="${HPC4_IVANTI_WAIT_SECONDS:-180}"
DEFAULT_MATCH="${HPC4_IVANTI_CONNECTION_MATCH:-${1:-}}"
CONNECTION_INDEX="${HPC4_IVANTI_CONNECTION_INDEX:-}"

usage() {
    cat <<EOF
[hpc4] usage:
  bash "${SCRIPT_DIR}/ivanti-up-local.sh" [connection-name-or-url-fragment]
  bash "${SCRIPT_DIR}/ivanti-up-local.sh" --list

任意設定（${USER_CONF} に書けます）:
  HPC4_IVANTI_CONNECTION_MATCH="HKUST"
  HPC4_IVANTI_CONNECTION_INDEX="0"
  HPC4_IVANTI_WAIT_SECONDS=180
EOF
}

osascript_status_hint() {
    local code="${1:-}"
    case "$code" in
        *-1743*)
            err "macOS Automation 権限で Ivanti の AppleScript 操作が拒否されました。"
            err "System Settings > Privacy & Security > Automation で Terminal/iTerm/Codex から Ivanti Secure Access の制御を許可してください。"
            ;;
        *-10827*)
            err "Ivanti Secure Access はまだ AppleScript 応答可能な状態ではありません。"
            ;;
        *)
            err "Ivanti Secure Access の AppleScript 操作に失敗しました。"
            ;;
    esac
}

ivanti_list_connections() {
    osascript <<'APPLESCRIPT'
set sep to ASCII character 9
set lf to ASCII character 10
tell application id "net.pulsesecure.Pulse-Secure"
    set rows to {}
    repeat with c in every connection
        set idx to (indexStr of c) as text
        set nm to (connectionDisplayName of c) as text
        set url to (connectionServerUrl of c) as text
        set st to (connectionStatus of c) as text
        set btn to (connectionButtonTitle of c) as text
        set end of rows to idx & sep & nm & sep & url & sep & st & sep & btn
    end repeat
end tell
set AppleScript's text item delimiters to lf
set out to rows as text
set AppleScript's text item delimiters to ""
return out
APPLESCRIPT
}

ivanti_press_connect() {
    local idx="$1"
    osascript - "$idx" <<'APPLESCRIPT'
on run argv
    set idx to item 1 of argv
    tell application id "net.pulsesecure.Pulse-Secure"
        activate
        do PulseMainUI command "CONNECTBUTTON" ConnectionIndexStr idx
    end tell
end run
APPLESCRIPT
}

ensure_ivanti_running() {
    if [[ ! -d "$APP_PATH" ]]; then
        err "Ivanti Secure Access.app が見つかりません: ${APP_PATH}"
        exit 1
    fi

    if ! pgrep -f "Ivanti Secure Access.app/Contents/MacOS/Ivanti Secure Access" >/dev/null 2>&1; then
        log "Ivanti Secure Access を起動します。"
        open -g -a "$APP_PATH" >/dev/null 2>&1 || {
            err "Ivanti Secure Access を起動できませんでした: ${APP_PATH}"
            exit 1
        }
    fi
}

wait_for_connection_store() {
    local start now out rc
    start="$(date +%s)"
    while :; do
        out="$(ivanti_list_connections 2>&1)"
        rc=$?
        if (( rc == 0 )); then
            printf '%s\n' "$out"
            return 0
        fi
        now="$(date +%s)"
        if (( now - start >= 30 )); then
            osascript_status_hint "$out"
            return "$rc"
        fi
        sleep 1
    done
}

choose_connection_index() {
    local rows="$1" match="${2:-}" count idx

    if [[ -n "$CONNECTION_INDEX" ]]; then
        printf '%s' "$CONNECTION_INDEX"
        return 0
    fi

    if [[ -n "$match" ]]; then
        idx="$(printf '%s\n' "$rows" | awk -F '\t' -v m="$match" '
            BEGIN { m=tolower(m) }
            tolower($0) ~ m { print $1; exit }
        ')"
        [[ -n "$idx" ]] && { printf '%s' "$idx"; return 0; }
    fi

    idx="$(printf '%s\n' "$rows" | awk -F '\t' '
        tolower($0) ~ /(hkust|ust\.hk|143\.89)/ { print $1; exit }
    ')"
    [[ -n "$idx" ]] && { printf '%s' "$idx"; return 0; }

    count="$(printf '%s\n' "$rows" | awk 'NF{n++} END{print n+0}')"
    if [[ "$count" == "1" ]]; then
        printf '%s\n' "$rows" | awk -F '\t' 'NF{print $1; exit}'
        return 0
    fi

    if [[ -t 0 && -t 1 ]]; then
        warn "HKUST の Ivanti connection を一意に選べませんでした。"
        printf "[hpc4] Ivanti connections:\n"
        printf '%s\n' "$rows" | awk -F '\t' '{printf "  index=%s  name=%s  url=%s  status=%s  button=%s\n", $1, $2, $3, $4, $5}'
        printf "[hpc4] 使う connection index を入力してください: "
        read -r idx
        [[ -n "$idx" ]] && { printf '%s' "$idx"; return 0; }
    fi

    err "対象 connection を選べませんでした。引数か ${USER_CONF} で HPC4_IVANTI_CONNECTION_MATCH / HPC4_IVANTI_CONNECTION_INDEX を指定してください。"
    return 1
}

target_row_for_index() {
    local rows="$1" idx="$2"
    printf '%s\n' "$rows" | awk -F '\t' -v idx="$idx" '$1==idx {print; exit}'
}

wait_for_hkust_iface() {
    local start now iface
    start="$(date +%s)"
    while :; do
        iface="$(find_hkust_iface)"
        if [[ -n "$iface" ]]; then
            ok "HKUST 圏内 IF を検出: ${iface} (IP=$(iface_ipv4 "$iface"))"
            return 0
        fi
        now="$(date +%s)"
        if (( now - start >= WAIT_SECONDS )); then
            err "Ivanti 認証完了後の HKUST IF を ${WAIT_SECONDS} 秒以内に検出できませんでした。"
            err "Ivanti Secure Access の認証画面・接続状態を確認してから再実行してください。"
            return 1
        fi
        sleep 2
    done
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

ensure_ivanti_running
rows="$(wait_for_connection_store)" || exit $?

if [[ "${1:-}" == "--list" ]]; then
    printf "[hpc4] Ivanti connections:\n"
    printf '%s\n' "$rows" | awk -F '\t' '{printf "  index=%s  name=%s  url=%s  status=%s  button=%s\n", $1, $2, $3, $4, $5}'
    exit 0
fi

if [[ -n "$(find_hkust_iface)" ]]; then
    ok "HKUST 圏内 IF は既にあります。HPC4 経路診断に進みます。"
else
    idx="$(choose_connection_index "$rows" "$DEFAULT_MATCH")" || exit $?
    row="$(target_row_for_index "$rows" "$idx")"
    button="$(printf '%s' "$row" | awk -F '\t' '{print $5}')"
    status="$(printf '%s' "$row" | awk -F '\t' '{print $4}')"

    log "Ivanti connection index=${idx} を使います。"
    if printf '%s\n%s\n' "$button" "$status" | grep -Eiq 'disconnect|connected|connecting|reconnecting'; then
        log "Ivanti は接続中または接続済みの表示です。Connect ボタンは押さずに HKUST IF を待ちます。"
    else
        log "Ivanti の Connect ボタンを押します。認証画面が出たら password / 2FA / SSO を完了してください。"
        out="$(ivanti_press_connect "$idx" 2>&1)" || {
            osascript_status_hint "$out"
            exit 1
        }
    fi
    wait_for_hkust_iface || exit $?
fi

bash "${SCRIPT_DIR}/net-up.sh"
rc=$?
case "$rc" in
    0) exit 0 ;;
    2|3)
        log "sudo が必要な経路・pf 調整に進みます。"
        exec bash "${SCRIPT_DIR}/net-up-local.sh"
        ;;
    *) exit "$rc" ;;
esac
