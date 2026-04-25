#!/bin/bash
# ネットワーク層の準備：HPC4 (143.89.184.3) に届く経路を確保する。
#
# 段階的アプローチ（やること最小化）：
#   (0) 原因ベース事前判定（probe なし、即時）：interface 状態だけで「外部ネット
#       + VPN なし」「経路候補なし」を確定して即 exit。timeout を待たせない。
#   (1) 既に届く → 何もしない
#   (2) 経路候補（en0 / Ivanti utun）を検出しルート追加 → 届けば終了
#   (3) まだ届かない かつ フル VPN (NordVPN / SurfShark / ExpressVPN / Proton 等)
#       が default を奪っているようなら、pf anchor で HPC4 宛だけ例外許可
#
# sudo が必要なのは (2)(3) の追加適用時のみ。(0)(1) なら sudo 不要。

set -u
source "$(dirname "$0")/common.sh"

# --- (0) 原因ベース事前判定 -------------------------------------------------
# probe（ping/TCP22）に頼らず interface 状態だけで結論を出す。
# 「外部ネット+VPNなし」のように到達不可と確定するケースを 0 秒で弾く。
verdict="$(classify_network)"
case "$verdict" in
    ng:no-reach:*|ng:no-route)
        render_network_verdict "$verdict" >&2
        err "原因ベース判定で接続不可と確定しました。ネットワーク修正後に再実行してください"
        exit 1
        ;;
esac

# --- (1) 既に届くなら終了 ----------------------------------------------------
if tcp22_ok 3; then
    iface="$(current_hpc4_iface)"
    ok "HPC4 に到達済み（経由: ${iface:-default route}）"
    exit 0
fi

# --- (2) 経路候補を検出 -----------------------------------------------------
EN0_GW="$(detect_en0_gw)"
IVANTI_IF="$(detect_ivanti_iface || true)"
log "検出結果："
log "  en0 gateway : ${EN0_GW:-(なし)}"
log "  Ivanti utun : ${IVANTI_IF:-(なし)}"

MODE=""
# Ivanti (HKUST SSL VPN) がある場合は最優先。
# 理由：Ivanti が立っているなら 143.89/16 は必ず utun 経由で届く。
# 逆に en0 が HKUST 圏外（テザリング、自宅 wifi 等）なら en0 経由は無力。
# オンキャンパス en0 でも Ivanti は split-tunnel なので共存して問題なし。
if [[ -n "$IVANTI_IF" ]]; then
    MODE="ivanti"
elif [[ -n "$EN0_GW" ]]; then
    MODE="en0"
else
    err "HPC4 への経路候補が見つかりません。"
    err "  - オンキャンパス: eduroam / HKUST 有線 に接続してください"
    err "  - オフキャンパス: HKUST VPN (Ivanti Secure Access) を起動してください"
    exit 1
fi
log "経路モード: $MODE"

# ルート追加
if [[ "$MODE" == "en0" ]]; then
    if netstat -rn 2>/dev/null | grep -E "^${HPC4_IP}[[:space:]]" | grep -q "en0"; then
        ok "ルート ${HPC4_IP} → en0 は設定済み"
    else
        log "sudo route add -host ${HPC4_IP} ${EN0_GW}"
        sudo route add -host "$HPC4_IP" "$EN0_GW" || { err "route add に失敗"; exit 1; }
        ok "ルート追加完了"
    fi
else  # ivanti
    if [[ "$(current_hpc4_iface)" == "$IVANTI_IF" ]]; then
        ok "ルート ${HPC4_IP} → ${IVANTI_IF} は設定済み"
    else
        sudo route delete -host "$HPC4_IP" 2>/dev/null || true
        log "sudo route add -host ${HPC4_IP} -interface ${IVANTI_IF}"
        sudo route add -host "$HPC4_IP" -interface "$IVANTI_IF" || { err "route add に失敗"; exit 1; }
        ok "ルート追加完了（Ivanti 経由）"
    fi
fi

# 再テスト
if tcp22_ok 3; then
    ok "HPC4 到達確認（経由: $(current_hpc4_iface)）"
    exit 0
fi

# --- (3) まだ届かない：フル VPN のキルスイッチを疑う ------------------------
# NordVPN / SurfShark 等のキルスイッチ型フル VPN が稼働していると、en0 経路も
# Ivanti utun も等しく pf で塞がれる（Ivanti 側も利用者空間で utun9 → en0 と
# 再カプセル化する際に en0 出力が落とされる、あるいは pf が utun9 発のパケットも
# 弾くため）。MODE に応じて該当 IF の HPC4 宛だけを pass する anchor を入れる。
vpn_if="$(fullvpn_default_route || true)"
if [[ -n "$vpn_if" ]]; then
    warn "default route が ${vpn_if} に奪われています（NordVPN / SurfShark 等が稼働中と推定）"
    warn "このタイプの VPN は非VPNトラフィックを pf で遮断するため、"
    warn "HPC4 宛だけ例外を許可する anchor を適用します（mode=${MODE}）。"
    if [[ "$MODE" == "en0" ]]; then
        sudo pfctl -a "$PF_ANCHOR" -f - <<EOF
pass out quick on en0 inet proto tcp from any to ${HPC4_IP} flags any keep state
pass out quick on en0 inet proto icmp from any to ${HPC4_IP} keep state
EOF
    else  # ivanti
        sudo pfctl -a "$PF_ANCHOR" -f - <<EOF
pass out quick on ${IVANTI_IF} inet from any to ${HPC4_IP} flags any keep state
pass in  quick on ${IVANTI_IF} inet from ${HPC4_IP} to any flags any keep state
EOF
    fi
    ok "pf anchor ${PF_ANCHOR} を適用"
else
    warn "到達できませんが、フル VPN の痕跡は見つかりませんでした。"
    warn "  - 別のファイアウォール製品 (Little Snitch / LuLu 等) が塞いでいる可能性"
    warn "  - 一時的なネットワーク障害の可能性"
fi

# 最終テスト
if tcp22_ok 3; then
    ok "HPC4 到達確認（経由: $(current_hpc4_iface)）"
    exit 0
fi

err "すべての対策を試しましたが HPC4 に届きません。"
err "scripts/status.sh で現状を取り、手動で診断してください："
err "  - VPN を再接続してから再実行"
err "  - pfctl -a ${PF_ANCHOR} -sr でルール確認"
err "  - ssh -vvv で詳細ログ"
exit 2
