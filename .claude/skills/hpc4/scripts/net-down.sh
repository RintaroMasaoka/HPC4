#!/bin/bash
# net-up.sh の手順で入った host route と ControlMaster ソケットを取り外す。
# 通常は不要（Mac 再起動で host route は消える）。トラブル切り分け用。
#
# AI 実行では sudo しない。user が net-down-local.sh を自分の Terminal で
# 実行した時だけ route / pf の削除を行う。

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "HPC4 host route (${iface}) を削除します"
        sudo_cmd route -n delete -host "$HPC4_IP" 2>/dev/null || warn "route 削除に失敗"
    else
        log "HPC4 host route が ${iface} に固定されています。削除には sudo が必要です。"
        log "別ターミナルで helper を実行してください："
        log "    bash \"$(dirname "$0")/net-down-local.sh\""
    fi
else
    log "HPC4 host route は存在しません"
fi

if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
    log "pf anchor ${PF_ANCHOR} をフラッシュします"
    sudo_cmd pfctl -a "$PF_ANCHOR" -F rules 2>/dev/null || warn "pf ルール削除に失敗（存在しなかった可能性）"
else
    log "kill-switch 貫通用 pf anchor (${PF_ANCHOR}) もフラッシュする場合は同じ helper が処理します"
fi

# ControlMaster の close は sudo 不要
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "ControlMaster ソケットを close"
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
    ok "ControlMaster ソケット closed"
fi
