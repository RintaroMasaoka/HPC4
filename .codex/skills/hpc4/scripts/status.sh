#!/bin/bash
# HPC4 接続に関わる状態を一覧表示。出力は terminal で直読する前提の日本語。
# Claude が落ちていても user がこの出力だけで次の action を判断できることを目標とする。
#
# 判定の順番（早い段階で診断したい問題を先に出す）：
#   1. user.conf.local
#   2. HKUST 圏内能力（IF が 143.89/16 IP を持っているか）
#   3. stale な HPC4 host pin が残っていないか
#   4. 現在の HPC4 egress が HKUST 圏内 IF か
#   5. TCP 22 疎通
#   6. passwordless SSH / ControlMaster

set -u
source "$(dirname "$0")/common.sh"

printf "## HPC4 接続状態 (%s)\n" "$(date '+%F %T')"

# Codex sandbox / 非 escalated 環境では route socket / ICMP / TCP probe が
# 軒並み false negative になる。この flag が立つ場合、route 系の判定失敗は
# [ng] ではなく [?] (sandbox restricted) として表示し、user に「不要な
# sudo route add が必要」と誤認させない。
restricted=0
if route_probe_restricted; then
    restricted=1
fi

# --- (1) 個人設定 -----------------------------------------------------------
if [[ -f "$USER_CONF" ]] && [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    printf "  [ok]   user.conf.local 読み込み済み (HPC4_USER=%s, account=%s, partition=%s)\n" \
        "$HPC4_USER" "$HPC4_ACCOUNT" "$HPC4_PARTITION"
else
    printf "  [err]  user.conf.local 未作成。bash \"%s/scripts/write-user-conf.sh\" <itso_username> を実行してください\n" "$SKILL_DIR"
fi

if (( restricted )); then
    printf "  [?]    route socket 制限を検出（Codex sandbox / 非 escalated 環境の特徴）\n"
    printf "         経路・疎通・SSH 認証の判定は false negative になり得るため [?] で表示します\n"
    printf "         実際は HPC4 に届いている可能性があります。確実な判定は別ターミナルから\n"
fi

# --- (2) HKUST 圏内能力（routing と独立） ----------------------------------
hkust_iface="$(find_hkust_iface)"

if [[ -z "$hkust_iface" ]]; then
    printf "  [ng]   HKUST 到達能力なし：HKUST 圏内 IF が見つかりません\n"
    printf "         → HKUST キャンパス内の eduroam (10.79/16 NAT) または HKUST 有線（オンキャンパスの場合）\n"
    printf "         → Ivanti Secure Access (HKUST SSL VPN) を起動（オフキャンパスの場合）\n"
    printf "         備考：eduroam は federated なので HKUST 外（DT Hub 等）でも繋がりますが\n"
    printf "               HKUST 構成員向け eduroam でないと HPC4 に届きません。詳細は .codex/skills/hpc4/policy.md\n"
    exit 0
fi

hkust_ip="$(ifconfig "$hkust_iface" 2>/dev/null | awk '/inet (143\.89\.|10\.79\.)/{print $2; exit}')"
printf "  [ok]   HKUST 圏内 IF：%s (IP=%s)\n" "$hkust_iface" "${hkust_ip:-?}"

# --- (3) stale pin 検出 ----------------------------------------------------
existing_pin="$(current_hpc4_iface)"

if [[ -n "$existing_pin" ]] && ! iface_is_hkust_capable "$existing_pin"; then
    printf "  [ng]   HPC4 host route：%s に固定済みだが HKUST 圏外（stale pin）\n" "$existing_pin"
    printf "         longest-prefix-match でこの pin が natural route を上書きしています\n"
    printf "         → 別ターミナルで bash \"%s/scripts/net-up-local.sh\" を実行\n" "$SKILL_DIR"
    exit 0
fi

# --- (4) 現在の egress -----------------------------------------------------
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"

if [[ -z "$egress" ]] || ! iface_is_hkust_capable "$egress"; then
    if (( restricted )); then
        printf "  [?]    HPC4 egress：判定不能（route socket 制限）\n"
    else
        printf "  [ng]   HPC4 egress：%s（HKUST 圏外）\n" "${egress:-なし}"
        printf "         HKUST 圏内 IF (%s) はあるのに kernel が別 IF を選んでいます\n" "$hkust_iface"
        printf "         → 別ターミナルで bash \"%s/scripts/net-up-local.sh\" を実行\n" "$SKILL_DIR"
        exit 0
    fi
elif [[ -n "$existing_pin" ]]; then
    printf "  [ok]   HPC4 経路：%s 経由（host pin あり）\n" "$egress"
else
    printf "  [ok]   HPC4 経路：%s 経由（kernel の自然な longest-prefix-match）\n" "$egress"
fi

# --- (5) 疎通 ---------------------------------------------------------------
if tcp22_ok 5; then
    printf "  [ok]   TCP 22 到達 OK\n"
elif (( restricted )); then
    printf "  [?]    TCP 22 疎通：判定不能（sandbox で probe が制限されている可能性）\n"
else
    printf "  [ng]   TCP 22 不通：L3 経路は OK だが L4 で塞がれている\n"
    printf "         → bash \"%s/scripts/net-up.sh\" で詳細診断\n" "$SKILL_DIR"
    printf "         → 他 VPN クライアントの kill-switch / packet filter 設定を確認\n"
    exit 0
fi

# --- (6) 認証層 -------------------------------------------------------------
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    if ssh_passwordless_ok; then
        printf "  [ok]   passwordless SSH 成立\n"
    elif (( restricted )); then
        printf "  [?]    passwordless SSH：判定不能（sandbox で BatchMode SSH が制限されている可能性）\n"
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
