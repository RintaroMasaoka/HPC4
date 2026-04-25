#!/bin/bash
# HPC4 接続に関わる状態を一覧表示。出力は terminal で直読する前提の日本語。
# Claude が落ちていても user がこの出力だけで次の action を判断できることを目標とする。

set -u
source "$(dirname "$0")/common.sh"

printf "## HPC4 接続状態 (%s)\n" "$(date '+%F %T')"

# --- 個人設定 ---------------------------------------------------------------
if [[ -f "$USER_CONF" ]] && [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    printf "  [ok]   user.conf.local 読み込み済み (HPC4_USER=%s, account=%s, partition=%s)\n" \
        "$HPC4_USER" "$HPC4_ACCOUNT" "$HPC4_PARTITION"
else
    printf "  [err]  user.conf.local 未作成。bash .claude/skills/hpc4/scripts/write-user-conf.sh <itso_username> を実行してください\n"
fi

# --- ネットワーク状態 -------------------------------------------------------
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"
existing_pin="$(current_hpc4_iface)"

if [[ -z "$egress" ]]; then
    printf "  [ng]   HPC4 経路：kernel が一切経路を返しません\n"
    printf "         → eduroam / HKUST 有線 / Ivanti のいずれかに接続してください\n"
    exit 0
fi

egress_ip="$(ifconfig "$egress" 2>/dev/null | awk '/inet /{print $2; exit}')"

if iface_has_hkust_ip "$egress"; then
    printf "  [ok]   HPC4 経路：%s (IP=%s) 経由で HKUST 圏内\n" "$egress" "${egress_ip:-?}"
else
    printf "  [ng]   HPC4 経路：%s (IP=%s) ←この IF は HKUST 圏外（143.89/16 IP を持っていない）\n" "$egress" "${egress_ip:-?}"
    printf "         default fallback で流れているだけで実際には HPC4 に届きません\n"
    printf "         → HKUST VPN (Ivanti Secure Access) を起動してください（オフキャンパスの場合）\n"
    printf "         → eduroam か HKUST 有線に接続してください（オンキャンパスの場合）\n"
    exit 0
fi

if [[ -n "$existing_pin" ]]; then
    printf "  -      HPC4 host route pin：%s に固定済み\n" "$existing_pin"
else
    printf "  -      HPC4 host route pin：なし（kernel の自然な longest-prefix-match に依拠）\n"
fi

# --- 疎通 -------------------------------------------------------------------
if tcp22_ok 5; then
    printf "  [ok]   TCP 22 到達 OK\n"
else
    printf "  [ng]   TCP 22 不通：L3 経路は OK だが L4 で塞がれている\n"
    printf "         → bash .claude/skills/hpc4/scripts/net-up.sh を実行（pin して再判定）\n"
    printf "         → それでも不通なら他 VPN クライアントのキルスイッチ設定を見直してください\n"
    exit 0
fi

# --- 認証層 ------------------------------------------------------------------
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    if ssh_passwordless_ok; then
        printf "  [ok]   passwordless SSH 成立\n"
    else
        printf "  [ng]   passwordless SSH 未成立（公開鍵の登録が必要）\n"
        printf "         → ssh-copy-id -i ~/.ssh/id_ed25519.pub %s@%s （別ターミナルで一度だけ）\n" "$HPC4_USER" "$HPC4_HOST"
    fi

    if cm_alive; then
        printf "  [ok]   ControlMaster ソケット生存\n"
    else
        printf "  -      ControlMaster 未起動（初回 ssh で自動起動される）\n"
    fi
fi
