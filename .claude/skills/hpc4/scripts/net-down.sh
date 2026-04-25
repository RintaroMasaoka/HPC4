#!/bin/bash
# net-up.sh で入れたルートと pf anchor を取り外す。
# 通常は不要（Mac 再起動で消える）。トラブル切り分け用。

set -u
source "$(dirname "$0")/common.sh"

iface="$(current_hpc4_iface)"
if [[ -n "$iface" ]]; then
    log "ルート ${HPC4_IP} (${iface}) を削除"
    sudo route delete -host "$HPC4_IP" 2>/dev/null || warn "ルート削除に失敗"
else
    log "ルートは既に存在しません"
fi

log "pf anchor ${PF_ANCHOR} をフラッシュ"
sudo pfctl -a "$PF_ANCHOR" -F rules 2>/dev/null || warn "pf ルール削除に失敗（存在しなかった可能性）"

# ControlMaster も閉じる
if [[ -n "${HPC4_USER:-}" ]] && [[ "$HPC4_USER" != "your_itso_username" ]] && cm_alive; then
    log "ControlMaster ソケットを close"
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O exit hpc4 2>/dev/null || true
fi

ok "teardown 完了"
