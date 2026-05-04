#!/bin/bash
# HPC4 (143.89.184.3) への到達経路を診断する。
#
# 設計：
#   - AI 実行では sudo を呼ばない（user 委任が基本ルール）。
#   - user が net-up-local.sh を自分の Terminal で実行した時だけ sudo を許可する。
#   - 触る対象を案内するのは HPC4 IP の host route ただ 1 つ。
#   - 既存 pin が HKUST 圏外を指している stale 状態と、そもそも HKUST 圏外に居る
#     状態を **別の error path で** 報告する（昔は両方とも「圏外」に合流していた）。
#   - L4 で塞がれている時は VPN クライアント GUI 操作の手順を terminal 直読の日本語で出す。
#
# Exit code:
#   0  経路 OK + TCP 22 到達 OK
#   1  HKUST 圏内 IF が一つもない（network 状態を直す必要あり）
#   2  L3 経路は OK だが TCP 22 不通（L4 遮断）
#   3  user Terminal helper による sudo 操作が必要
#   4  route socket が sandbox / permission で制限されており判定不能

set -u
source "$(dirname "$0")/common.sh"

# --- (0) TCP fast-path：TCP 22 が既に通れば routing は全て正常 ---------------
# eduroam NAT (10.79/16) + NordVPN 同居など、IF 判定では捕捉しにくい構成でも
# 実際に届いているなら診断をスキップして即 OK を返す。
if tcp22_ok 3; then
    ok "TCP 22 到達 OK（routing 判定スキップ）"
    exit 0
fi

# --- (0.5) sandbox / permission 制限：route socket が塞がれているか ----------
# Codex sandbox や非 escalated 環境では route get / ping / 一部 TCP probe が
# 軒並み false negative になり、実際は届いているのに「経路欠落」と誤診断される。
# この状態で sudo route add を促すと、(a) 操作自体が permission 拒否で失敗し、
# (b) 実際には不要な route 追加を user に促してしまう。判定不能で即時終了する。
if route_probe_restricted; then
    err "route socket が制限されています（Codex sandbox / 非 escalated 環境の特徴）。"
    err "この状態では route get / ping / 一部 TCP probe が実体と無関係に false negative"
    err "を返すため、経路診断ができません。実際には HPC4 に届いている可能性があります。"
    err ""
    err "  → 別ターミナル（permission 制限のないシェル）で同じ script を再実行してください。"
    err "    判定不能のまま sudo route add を勧めることはしません。"
    exit 4
fi

# --- (1) HKUST 圏内能力の有無を判定 ----------------------------------------
# (a) 143.89/16 IP を直接持つ IF
# (b) eduroam NAT (10.79/16) 経由で 143.89.x への route が既存
# (c) route get が physical IF → private IP の場合（NordVPN なし）
# (d) 10.79/16 IP を持つ物理 IF（HKUST eduroam NAT の特徴）
hkust_iface="$(find_hkust_iface)"

if [[ -z "$hkust_iface" ]]; then
    err "あなたの Mac には HKUST 到達能力を持つ IF が一つもありません。"
    err "  → HKUST キャンパス内の eduroam (10.79/16 NAT) または HKUST 有線（オンキャンパスの場合）"
    err "  → Ivanti Secure Access (HKUST SSL VPN) を起動（オフキャンパスの場合）"
    err ""
    err "備考：eduroam は federated なので HKUST 以外（DT Hub 等の HKSTP 施設、他大学、空港）でも"
    err "      同じ SSID で繋がりますが、HKUST 構成員向け eduroam でないと HPC4 に届きません。"
    err "      詳細は .claude/skills/hpc4/policy.md。"
    exit 1
fi

# --- (2) stale pin の検出 -------------------------------------------------
# 既存の host pin が HKUST 圏外 IF を指しているなら、natural route を上書きする
# 害悪な存在。delete を user に依頼する。
existing_pin="$(current_hpc4_iface)"

if [[ -n "$existing_pin" ]] && ! iface_is_hkust_capable "$existing_pin"; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "stale HPC4 host route (${existing_pin}) を削除します"
        sudo_cmd route -n delete -host "$HPC4_IP" || exit $?
        ok "stale route を削除しました。再判定します。"
        exec bash "$0"
    fi
    err "前回 set した HPC4 host route が ${existing_pin} (HKUST 圏外) を指したまま残っています。"
    err "削除には sudo が必要です。別ターミナルで helper を実行してください："
    err "    bash \"$(dirname "$0")/net-up-local.sh\""
    exit 3
fi

# --- (3) 自然な route が HKUST 圏内を経由するか ---------------------------
# pin が無いか、pin が正しい場合、kernel は HKUST IF に流すはず。
# それでも非 HKUST IF が選ばれている稀ケースは host pin で強制する必要がある。
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"

if [[ -z "$egress" ]] || ! iface_is_hkust_capable "$egress"; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "HPC4 host route を ${hkust_iface} に固定します"
        hpc4_pin_route "$hkust_iface" || exit $?
        ok "host route を追加しました。再判定します。"
        exec bash "$0"
    fi
    err "HKUST 圏内 IF (${hkust_iface}) は存在しますが、kernel は HPC4 を別 IF (${egress:-なし}) に流しています。"
    err "host pin には sudo が必要です。別ターミナルで helper を実行してください："
    err "    bash \"$(dirname "$0")/net-up-local.sh\""
    exit 3
fi

# --- (4) 経路 OK。TCP 22 疎通テスト --------------------------------------
if [[ -n "$existing_pin" ]]; then
    ok "HPC4 経路 OK：${egress} 経由（host pin あり）"
else
    ok "HPC4 経路 OK：${egress} 経由（kernel の自然な longest-prefix-match）"
fi

if tcp22_ok 5; then
    ok "TCP 22 到達 OK"
    exit 0
fi

# --- (5) L4 で塞がれている：kill-switch 系 VPN なら pf anchor で貫通させる ----
# default が NordVPN 系の POINTOPOINT IF に握られている時、その VPN の pf rules が
# en0 outbound を一律 drop するため、host route が正しくても TCP 22 が通らない。
# 対策：HPC4 宛だけ pass する pf anchor (PF_ANCHOR) を入れて kill-switch を貫通させる。
fullvpn_iface="$(fullvpn_default_route || true)"
if [[ -n "$fullvpn_iface" ]]; then
    if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
        log "HPC4 宛だけ通す pf anchor (${PF_ANCHOR}) を ${egress} に適用します"
        hpc4_apply_pf_anchor "$egress" || exit $?
        ok "pf anchor を適用しました。再判定します。"
        exec bash "$0"
    fi
    err "L3 は ${egress} で正しいですが TCP 22 が通りません。"
    err "default route が ${fullvpn_iface} (kill-switch 系フル VPN と推定) に奪取されており、"
    err "その pf rules が en0 outbound を遮断しているのが原因と推定されます。"
    err "pf anchor 適用には sudo が必要です。別ターミナルで helper を実行してください："
    err "    bash \"$(dirname "$0")/net-up-local.sh\""
    exit 3
fi

err "L3 ルーティングは ${egress} で正しいですが TCP 22 が通りません。L4 (firewall / packet filter) 側で塞がれています。"
err "default route は ${egress} の方へ向いているため kill-switch 系フル VPN は検出されませんでした。"
err ""
err "考えられる原因と対処（terminal だけで判断・実行できます）："
err ""
err "  1. 他 VPN クライアント (NordVPN 等) の kill-switch / packet filter が outbound を遮断している"
err "     → 当該 VPN クライアントの設定 GUI で 143.89.184.3 (or 143.89.0.0/16) を例外に追加"
err "       設定項目名は製品ごとに違う：split tunneling / allowed IPs / excluded IPs /"
err "       trusted apps / bypass list 等のラベルを探してください"
err ""
err "  2. NEPacketTunnelProvider (\`includeAllNetworks=true\`) で system 強制 tunnel"
err "     → user space からは override 不可。当該 VPN を一時停止してください"
err ""
err "  3. HKUST tunnel (Ivanti) の認証/再接続が未完了"
err "     → Ivanti Secure Access を一旦切って繋ぎ直してください"
exit 2
