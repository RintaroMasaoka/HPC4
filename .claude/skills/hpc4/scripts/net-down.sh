#!/bin/bash
# net-up.sh で入れた host route と ControlMaster ソケットを取り外す。
# 通常は不要（Mac 再起動で消える）。トラブル切り分け用。

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    log "ルート ${HPC4_IP} (${iface}) を削除"
    sudo route -n delete -host "$HPC4_IP" 2>/dev/null || warn "ルート削除に失敗"
else
    log "HPC4 host route は既に存在しません"
fi

# ControlMaster も閉じる
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "ControlMaster ソケットを close"
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
fi

ok "teardown 完了"
