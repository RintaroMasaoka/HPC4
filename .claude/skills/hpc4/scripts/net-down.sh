#!/bin/bash
# net-up.sh の手順で入った host route と ControlMaster ソケットを取り外す。
# 通常は不要（Mac 再起動で host route は消える）。トラブル切り分け用。
#
# route 削除は sudo が要るので user に案内する（user 委任が基本ルール）。
# ControlMaster の close は sudo 不要なのでそのまま実行する。

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    log "HPC4 host route が ${iface} に固定されています。削除には sudo が必要です。"
    log "別ターミナルで以下を 1 行実行してください："
    log ""
    log "    sudo route -n delete -host ${HPC4_IP}"
else
    log "HPC4 host route は存在しません"
fi

# ControlMaster の close は sudo 不要
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "ControlMaster ソケットを close"
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
    ok "ControlMaster ソケット closed"
fi
