#!/bin/bash
# HPC4 (143.89.184.3) への到達経路を診断する。
#
# 設計：
#   - Codex 実行では sudo を呼ばない（user 委任が基本ルール）。
#   - user が net-up-local.sh を自分の Terminal で実行した時だけ sudo を許可する。
#   - 触る対象を案内するのは HPC4 IP の host route ただ 1 つ。
#   - 既存 pin が HKUST 圏外を指している stale 状態と、そもそも HKUST 圏外に居る
#     状態を **別の error path で** 報告する（昔は両方とも「圏外」に合流していた）。
#   - user Terminal helper で L3 が正しいのに L4 だけ塞がれている時は、pf main
#     ruleset を 1 回だけ flush して再判定する。Codex 実行では sudo せず案内で止める。
#
# Exit code:
#   0  経路 OK + TCP 22 到達 OK
#   1  HKUST 圏内 IF が一つもない（network 状態を直す必要あり）
#   2  L3 経路は OK だが TCP 22 不通（L4 遮断）
#   3  user Terminal helper による sudo 操作が必要
#   4  route socket が sandbox / permission で制限されており判定不能
#   5  pin の add/delete を繰り返す発振状態（find_hkust_iface と
#      iface_is_hkust_capable の判定が食い違っている）を検出して中断

set -u
source "$(dirname "$0")/common.sh"

# --- (-1) 再帰深度ガード -----------------------------------------------------
# net-up.sh は stale pin 削除 / pin 追加 / pf main ruleset flush の後に exec bash "$0"
# で自分を再起動する。判定関数同士が食い違っていると無限ループに入って sudo
# プロンプトを延々と再表示してしまうので、深度を環境変数で持ち回って打ち切る。
HPC4_NET_UP_DEPTH="${HPC4_NET_UP_DEPTH:-0}"
HPC4_NET_UP_DEPTH=$((HPC4_NET_UP_DEPTH + 1))
export HPC4_NET_UP_DEPTH
if (( HPC4_NET_UP_DEPTH > 4 )); then
    err "net-up.sh が ${HPC4_NET_UP_DEPTH} 回連続で再判定されました（pin の add/delete 発振）。"
    err "find_hkust_iface() と iface_is_hkust_capable() の判定が食い違っている可能性が高いです。"
    err ""
    err "現状："
    err "  find_hkust_iface     : $(find_hkust_iface)"
    err "  current_hpc4_iface   : $(current_hpc4_iface)"
    err "  en0 IPv4             : $(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')"
    err "  default route        : $(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF, "via", $2; exit}')"
    err ""
    err "回避策：bash \"${SKILL_DIR}/scripts/net-down.sh\" で host pin を一度削除し、"
    err "        ネットワーク状態（HKUST eduroam か / Ivanti が起動しているか）を見直してください。"
    exit 5
fi

# --- (0a) NordVPN helper の kill-switch を proactive に flush ----------------
# NordVPN helper は VPN 接続時に pf main ruleset へ `block drop all` 系の
# kill-switch rule を入れる。これは com.apple/* anchor 配下より先に評価される
# ため、anchor で `pass quick` を入れても貫通できない（過去の `com.apple/hpc4`
# anchor 戦略は撤去済み）。唯一の対処は main rules ごと flush すること。
# NordVPN tunnel (utun7) と Codex の通信経路は kernel routing で維持されるので無害。
# NordVPN を Disconnect/Connect / Pause/Resume すると rules は再注入されるので、
# その都度 net-up-local.sh を再実行すれば再度 flush される。
#
# Codex 実行（sudo 不可）では skip。L4 で塞がれた時に reactive で user に案内する
# 後段ロジックが受ける。user terminal (net-up-local.sh) のときだけ proactive 動作。
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
    if sudo -n pfctl -s rules 2>/dev/null | grep -Eq '^block[[:space:]]+(drop|return)?([[:space:]]+quick)?[[:space:]]+(all|in|out)'; then
        log "pf main ruleset に kill-switch (block drop all) を検出。flush します。"
        if sudo_cmd pfctl -F rules >/dev/null; then
            ok "pf main rules flush 完了（NordVPN tunnel・Codex の通信経路は無傷）"
            export HPC4_PF_FLUSH_ATTEMPTED=1
        else
            err "pf main rules flush を自動実行できませんでした。sudo 認証を完了できる対話ターミナルから net-up-local.sh を再実行してください。"
            exit 2
        fi
    fi
fi

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
    err "      詳細は .codex/skills/hpc4/policy.md。"
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
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
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
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
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

# --- (5) L4 で塞がれている -----------------------------------------------
# 経路は HKUST 圏内 IF に出ているのに TCP 22 が通らない。user Terminal helper
# ならこの時点で「HKUST IF はある」「routing は正しい」ことが確定しているので、
# 最有力の pf main ruleset kill-switch とみなし、1 回だけ自動 flush して再判定する。
# Codex 実行では sudo prompt を扱えないため、自動実行せず helper の案内で止める。
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" && "${HPC4_PF_FLUSH_ATTEMPTED:-0}" != "1" ]]; then
    log "L3 は ${egress} で正しいため、pf main ruleset を flush して TCP 22 を再判定します"
    if sudo_cmd pfctl -F rules >/dev/null; then
        ok "pf main rules flush 完了。再判定します。"
        export HPC4_PF_FLUSH_ATTEMPTED=1
        exec bash "$0"
    fi
    err "pf main rules flush を自動実行できませんでした。sudo 認証を完了できる対話ターミナルから net-up-local.sh を再実行してください。"
    exit 2
fi

if [[ "${HPC4_PF_FLUSH_ATTEMPTED:-0}" == "1" ]]; then
    err "pf main ruleset を flush しましたが、TCP 22 はまだ通りません。"
    err "L3 経路は ${egress} で正しいため、残る候補は pf 以外の L4 / VPN tunnel 側です。"
    err ""
    err "考えられる原因："
    err ""
    err "  B. NEPacketTunnelProvider (\`includeAllNetworks=true\`) によるシステム強制 tunnel"
    err "     → user space からは override 不可。当該 VPN クライアントの設定を見直してください。"
    err ""
    err "  C. HKUST tunnel (Ivanti) の認証/再接続が未完了"
    err "     → Ivanti Secure Access の接続状態と認証完了を確認してください。"
    exit 2
fi

err "L3 経路は ${egress} で正しいですが TCP 22 が通りません。L4 (firewall / packet filter) 側で塞がれています。"
err ""
if [[ "${HPC4_ALLOW_INTERACTIVE_SUDO:-}" == "1" ]]; then
    err "net-up-local.sh は pf main ruleset flush を自動実行する設計ですが、この実行では完了できませんでした。"
    err "sudo 認証を完了できる対話ターミナルから net-up-local.sh を再実行してください。"
else
    err "Codex 実行では sudo prompt を扱えません。別ターミナルで helper を実行してください："
    err "    bash \"${SKILL_DIR}/scripts/net-up-local.sh\""
fi
exit 2
