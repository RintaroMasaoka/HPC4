#!/bin/bash
# HPC4 (143.89.184.3) 宛のトラフィックだけを HKUST に届く IF に host route で固定する。
#
# 設計の核：
#   - 触る対象は HPC4 IP の host route ただ 1 つ。default route や Claude 経路には絶対に触らない。
#   - VPN 製品の判別はしない。kernel に「HPC4 をどの IF に出す？」と聞いて、
#     その IF が 143.89/16 を持っているなら HKUST 経路ありと判断する。それだけ。
#   - L4 で塞がれている（VPN クライアントのキルスイッチ等）場合は、user に
#     out-of-band action（VPN GUI 操作）を terminal 直読の日本語で案内する。
#
# 冪等：何度呼んでも壊れない。既に正しく pin 済みなら no-op で抜ける。

set -u
source "$(dirname "$0")/common.sh"

# --- (1) kernel が現状で HPC4 をどの IF に出すか聞く -----------------------
# 既存の host pin が stale だと判定が歪むので、まず削除して kernel の natural な
# 判断を引き出す。失敗しても無視（pin が無いだけ）。
sudo route -n delete -host "$HPC4_IP" 2>/dev/null || true

resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"
gateway="$(printf '%s' "$resolve" | awk '{print $2}')"

if [[ -z "$egress" ]]; then
    err "HPC4 (${HPC4_IP}) への経路が一つもありません。"
    err "  - オンキャンパス：eduroam か HKUST 有線に接続してください"
    err "  - オフキャンパス：HKUST VPN (Ivanti Secure Access) を起動してください"
    exit 1
fi

# --- (2) その IF が実際に HKUST に届くか（143.89/16 IP を持っているか）-----
# 持っていなければ、kernel は default fallback で NordVPN 等に流しているだけで
# 実際には HKUST に届かない。pin しても無駄なので即誘導する。
if ! iface_has_hkust_ip "$egress"; then
    err "HPC4 への経路は ${egress} に向いていますが、${egress} は HKUST 圏内ではありません（143.89/16 IP を持っていません）。"
    err "  - オンキャンパス：eduroam か HKUST 有線に接続してください"
    err "  - オフキャンパス：HKUST VPN (Ivanti Secure Access) を起動してください"
    err "（NordVPN 等は香港外に出るだけで HPC4 には届きません。HKUST 圏に入る経路が別途必要です。）"
    exit 1
fi

# --- (3) host route を pin -------------------------------------------------
# 後で他 VPN が default を変えても、host route は longest-prefix で勝つので
# HPC4 だけは抜け続ける（これが skill の唯一の保険）。
egress_ip="$(ifconfig "$egress" 2>/dev/null | awk '/inet /{print $2; exit}')"
if [[ -n "$gateway" && "$gateway" != "$egress_ip" ]]; then
    log "sudo route -n add -host ${HPC4_IP} ${gateway}"
    sudo route -n add -host "$HPC4_IP" "$gateway" \
        || { err "route add に失敗。sudo の認証を確認してください"; exit 1; }
else
    log "sudo route -n add -host ${HPC4_IP} -interface ${egress}"
    sudo route -n add -host "$HPC4_IP" -interface "$egress" \
        || { err "route add に失敗。sudo の認証を確認してください"; exit 1; }
fi
ok "ルート固定: ${HPC4_IP} → ${egress}"

# --- (4) 疎通テスト --------------------------------------------------------
if tcp22_ok 5; then
    ok "HPC4 到達確認 (経由: ${egress})"
    exit 0
fi

# --- (5) L4 で塞がれている：user 単独で復旧できる形で案内 -------------------
err "経路は ${egress} に固定しましたが TCP 22 が通りません。L3 ルーティングは正しく、L4 (firewall / packet filter) 側で塞がれています。"
err ""
err "考えられる原因と対処（terminal だけで判断・実行できます）："
err ""
err "  1. 他 VPN クライアントの kill-switch / packet filter が outbound を遮断している"
err "     → 当該 VPN クライアントの設定 GUI で 143.89.184.3 (or 143.89.0.0/16) を例外に追加する"
err "       設定項目名は製品ごとに違う：split tunneling / allowed IPs / excluded IPs /"
err "       trusted apps / bypass list 等のラベルを探してください"
err ""
err "  2. NEPacketTunnelProvider (\`includeAllNetworks=true\`) で system 強制 tunnel"
err "     → user space からは override 不可。当該 VPN を一時停止してください"
err ""
err "  3. HKUST tunnel の認証/再接続が未完了"
err "     → Ivanti Secure Access を一旦切って繋ぎ直してください"
exit 2
