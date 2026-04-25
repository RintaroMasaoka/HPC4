#!/bin/bash
# HPC4 接続に関わる全状態を一覧表示。sudo 不要の項目のみ（読み取り専用）。

set -u
source "$(dirname "$0")/common.sh"

printf "## HPC4 接続状態 (%s)\n" "$(date '+%F %T')"

# 個人設定
if [[ -f "$USER_CONF" ]] && [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    printf "  [ok]   user.conf.local 読み込み済み (HPC4_USER=%s, account=%s, partition=%s)\n" \
        "$HPC4_USER" "$HPC4_ACCOUNT" "$HPC4_PARTITION"
else
    printf "  [err]  user.conf.local 未作成。'/hpc4 setup' を実行してください\n"
fi

# ネットワーク層（生情報）
en0_gw="$(detect_en0_gw)"
en0_ip="$(detect_en0_ip)"
ivanti_if="$(detect_ivanti_iface || true)"
hpc4_iface="$(current_hpc4_iface)"
printf "  - en0 IP / gateway : %s / %s\n" "${en0_ip:-(なし)}" "${en0_gw:-(なし)}"
if [[ -n "$ivanti_if" ]]; then
    printf "  - Ivanti VPN       : %s (IP=%s)\n" "$ivanti_if" "$(ifconfig "$ivanti_if" | awk '/inet /{print $2}')"
else
    printf "  - Ivanti VPN       : (未接続)\n"
fi
printf "  - HPC4 ルート       : %s\n" "${hpc4_iface:-(未設定)}"

# 原因ベース判定（probe を待たずに interface 状態のみで結論を出す）
verdict="$(classify_network)"
render_network_verdict "$verdict"

# ネットワーク verdict が NG ならここで打ち切る。ping や SSH の probe は
# timeout を待たされるだけで情報量がないので走らせない。
if [[ "$verdict" != ok:* ]]; then
    exit 0
fi

# 疎通（OK 判定の時のみ）
if ping_ok 2; then
    printf "  [ok]   ping %s OK\n" "$HPC4_IP"
else
    printf "  [ng]   ping %s 失敗（経路は OK だが疎通不可。'/hpc4 up' を試してください）\n" "$HPC4_IP"
fi

# 認証層（同じく OK 判定の時のみ）
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]]; then
    if ssh_passwordless_ok; then
        printf "  [ok]   passwordless SSH 成立\n"
    else
        printf "  [ng]   passwordless SSH 未成立 ('/hpc4 setup' で公開鍵登録が必要)\n"
    fi

    # ControlMaster の状態
    if cm_alive; then
        printf "  [ok]   ControlMaster ソケット生存\n"
    else
        printf "  -      ControlMaster 未起動（初回 ssh で自動起動される）\n"
    fi
fi
