#!/bin/bash
# HPC4 (143.89.184.3) への到達経路を診断し、必要に応じて user に sudo コマンドを案内する。
#
# 設計：
#   - script 自身は sudo を呼ばない（user 委任が基本ルール）。
#     Claude Code の Bash ツール経由だと sudo password / Touch ID が silent fail し、
#     呼び出し側が「成功した」と誤認するため、route 操作は一切 user に委ねる。
#   - 触る対象を案内するのは HPC4 IP の host route ただ 1 つ。
#   - 既存 pin が HKUST 圏外を指している stale 状態と、そもそも HKUST 圏外に居る
#     状態を **別の error path で** 報告する（昔は両方とも「圏外」に合流していた）。
#   - L4 で塞がれている時は VPN クライアント GUI 操作の手順を terminal 直読の日本語で出す。
#
# Exit code:
#   0  経路 OK + TCP 22 到達 OK
#   1  HKUST 圏内 IF が一つもない（network 状態を直す必要あり）
#   2  L3 経路は OK だが TCP 22 不通（L4 遮断）
#   3  user による sudo 操作が必要（stale pin 削除 or pin 追加）

set -u
source "$(dirname "$0")/common.sh"

# --- (1) HKUST 圏内能力の有無を ifconfig だけで判定 ------------------------
# routing table とは独立に「この Mac は 143.89/16 IP を持っているか」を見る。
# stale な host pin が route get の判定を歪めても、ここは騙されない。
hkust_iface="$(find_hkust_iface)"

if [[ -z "$hkust_iface" ]]; then
    err "あなたの Mac には 143.89/16 (HKUST) IPv4 を持つ IF が一つもありません。"
    err "  → HKUST キャンパス内の eduroam または HKUST 有線（オンキャンパスの場合）"
    err "  → Ivanti Secure Access (HKUST SSL VPN) を起動（オフキャンパスの場合）"
    err ""
    err "備考：eduroam は federated roaming service なので HKUST 以外（DT Hub 等の HKSTP"
    err "      施設、他大学、空港）でも同じ SSID で繋がりますが、HKUST IP は降ってこず"
    err "      HPC4 には届きません。詳細は .claude/skills/hpc4/policy.md。"
    exit 1
fi

# --- (2) stale pin の検出 -------------------------------------------------
# 既存の host pin が HKUST 圏外 IF を指しているなら、natural route を上書きする
# 害悪な存在。delete を user に依頼する。
existing_pin="$(current_hpc4_iface)"

if [[ -n "$existing_pin" ]] && ! iface_has_hkust_ip "$existing_pin"; then
    err "前回 set した HPC4 host route が ${existing_pin} (HKUST 圏外) を指したまま残っています。"
    err "longest-prefix-match でこの stale pin が natural route を上書きしてしまうので、削除が必要です。"
    err ""
    err "別ターミナルで以下を 1 行実行してください："
    err ""
    err "    sudo route -n delete -host ${HPC4_IP}"
    err ""
    err "完了したら同じ script をもう一度叩いてください（自動的に再判定します）。"
    exit 3
fi

# --- (3) 自然な route が HKUST 圏内を経由するか ---------------------------
# pin が無いか、pin が正しい場合、kernel は HKUST IF に流すはず。
# それでも非 HKUST IF が選ばれている稀ケースは host pin で強制する必要がある。
resolve="$(hpc4_route_resolve)"
egress="$(printf '%s' "$resolve" | awk '{print $1}')"

if [[ -z "$egress" ]] || ! iface_has_hkust_ip "$egress"; then
    err "HKUST 圏内 IF (${hkust_iface}) は存在しますが、kernel は HPC4 を別 IF (${egress:-なし}) に流しています。"
    err "host pin で ${hkust_iface} に固定する必要があります。別ターミナルで以下を 1 行実行してください："
    err ""
    err "    sudo route -n add -host ${HPC4_IP} -interface ${hkust_iface}"
    err ""
    err "完了したらこの script をもう一度叩いてください。"
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

# --- (5) L4 で塞がれている：user 単独で復旧できる形で案内 -------------------
err "L3 ルーティングは ${egress} で正しいですが TCP 22 が通りません。L4 (firewall / packet filter) 側で塞がれています。"
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
