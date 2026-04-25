#!/bin/bash
# 共通定数とヘルパー。他スクリプトから source される。

set -u

# --- グループ共通の固定パラメータ -------------------------------------------
HPC4_HOST="hpc4.ust.hk"
HPC4_IP="143.89.184.3"
PF_ANCHOR="main/hpc4"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${SKILL_DIR}/ssh_config"
USER_CONF="${SKILL_DIR}/user.conf.local"

# --- 個人設定の読み込み -----------------------------------------------------
# user.conf.local から HPC4_USER / HPC4_ACCOUNT / HPC4_PARTITION / HPC4_IDENTITY_FILE を取得。
# 無ければ setup を案内して exit。
if [[ -f "$USER_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONF"
fi

: "${HPC4_ACCOUNT:=watanabemc}"
: "${HPC4_PARTITION:=amd}"
: "${HPC4_IDENTITY_FILE:=}"

require_user_conf() {
    if [[ -z "${HPC4_USER:-}" ]]; then
        printf "[hpc4][err] %s\n" "個人設定 ${USER_CONF} がありません。setup フロー (scripts/write-user-conf.sh <itso_username>) を実行してください。" >&2
        exit 1
    fi
}

# --- ログ出力（絵文字なし） --------------------------------------------------
log()  { printf "[hpc4] %s\n" "$*"; }
ok()   { printf "[hpc4][ok] %s\n" "$*"; }
warn() { printf "[hpc4][warn] %s\n" "$*" >&2; }
err()  { printf "[hpc4][err] %s\n" "$*" >&2; }

# --- ネットワーク状態検出 ---------------------------------------------------

# en0 のデフォルトゲートウェイ（空文字なら未検出）
detect_en0_gw() {
    netstat -rn 2>/dev/null | awk '$1=="default" && $NF=="en0" {print $2; exit}'
}

# Ivanti (HKUST SSL VPN) の utun インタフェースを検出
# 143.89.* の IP を持つ utun を返す。無ければ空文字。
detect_ivanti_iface() {
    for i in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
        if ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | grep -q '^143\.89\.'; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# 現在 HPC4 宛がどのインタフェースに向いているか（"en0" / "utun9" / 空）
current_hpc4_iface() {
    netstat -rn 2>/dev/null | awk -v ip="$HPC4_IP" '$1==ip {print $NF; exit}'
}

# ping で疎通確認（引数：タイムアウト秒、既定 2）
ping_ok() {
    local t="${1:-2}"
    ping -c 2 -W "${t}000" "$HPC4_IP" >/dev/null 2>&1
}

# TCP 22 まで届くか（ICMP が塞がれる環境のバックアップ判定）
# 第 1 引数：timeout 秒（既定 5）。短時間判定したいときは小さい値を渡す。
tcp22_ok() {
    local t="${1:-5}"
    # /dev/tcp は bash 組み込み、外部コマンド不要。タイムアウトのため & + kill で囲む
    ( exec 3<>/dev/tcp/"$HPC4_IP"/22 ) >/dev/null 2>&1 &
    local pid=$!
    ( sleep "$t"; kill "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$killer" 2>/dev/null
    return $rc
}

# 「消費者向けフル VPN（NordVPN / SurfShark / ExpressVPN / Proton / Mullvad 等）」が
# 動いていると思われるか。症状ベースで検出する：
#   default route が utun/ppp/tap/wg 系の仮想 IF に向いており、かつそれが Ivanti
#   (143.89.*) でないなら、フル VPN が default を奪っていると判断する。
# キルスイッチで en0 上のパケットを pf で塞ぐタイプが対象で、これにより
# HPC4 宛を en0 経由で通すには pf anchor の例外許可が必要になる。
fullvpn_default_route() {
    # 仮想 IF 名の候補: utun*, ppp*, tap*, wg*
    local iface
    iface="$(netstat -rn 2>/dev/null \
        | awk '$1=="default" && ($NF ~ /^utun/ || $NF ~ /^ppp/ || $NF ~ /^tap/ || $NF ~ /^wg/) {print $NF; exit}')"
    [[ -z "$iface" ]] && return 1
    # Ivanti なら対象外
    local addr
    addr="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}')"
    if [[ -n "$addr" && "$addr" =~ ^143\.89\. ]]; then
        return 1
    fi
    echo "$iface"
    return 0
}

# en0 自身の IPv4 アドレス（空文字なら未割当）
detect_en0_ip() {
    ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}'
}

# 与えた IP が HPC4 と同じ /16 にあるか。
# HPC4 = 143.89.184.3 なので 143.89/16。
# 同 /16 なら NAT もファイアウォール越えもなく HPC4 へ直結できる、というのが本質。
# （143.89/16 は実態として HKUST の公式割当だが、判定の根拠は所属ではなく
# 「HPC4 に到達できるか」という reachability。）
is_in_hpc4_subnet() {
    [[ "${1:-}" =~ ^143\.89\. ]]
}

# ネットワーク状態を **HPC4 への到達性** という観点で分類し 1 行 verdict を返す。
# interface 状態（IP / utun / default route）のみから 0 秒で結論を出す。probe しない。
#
# 前提：HKUST の end-user ネット（eduroam / 有線 / Ivanti）は 143.89/16 を直接配布する。
# よって en0 が 143.89/16 でなく Ivanti utun も無い場合 = HKUST 外 = HPC4 不通、と確定できる。
#
# 出力フォーマット: <code>:<kind>[:<detail>]
#   ok:lan-reach:en0_ip=143.89.x.x          en0 が HPC4 と同 /16。LAN 直結
#   ok:vpn-tunnel:iface=utun9               Ivanti split-tunnel utun に 143.89.* IP
#   ng:fullvpn-hijack:iface=utunX           HKUST 到達手段はあるがフル VPN が default を奪取
#                                           （en0 が HKUST 圏内 or Ivanti が立っている時のみ。
#                                           net-up.sh で pf anchor を入れて救う）
#   ng:no-route                             en0 ゲートウェイも VPN tunnel も無い
#   ng:no-reach:en0_ip=172.16.x.x           en0 はあるが HKUST 外 + VPN 未接続
#                                           （pf anchor では救えない。要 Ivanti 起動 or 学内切替）
#
# 戻り値：ok なら 0、ng なら 1
#
# 設計上の要点：fullvpn-hijack 判定は **HKUST に届く下回り（en0 が 143.89/16
# にいる、または Ivanti utun が立っている）が既にある場合のみ** 出す。下回りが
# 無い時にこの verdict を出すと「net-up.sh で pf anchor を入れれば直る」と
# 誤誘導になる（pf anchor は経路の代わりにはならない）。
classify_network() {
    local en0_gw en0_ip ivanti_if fullvpn_if
    en0_gw="$(detect_en0_gw)"
    en0_ip="$(detect_en0_ip)"
    ivanti_if="$(detect_ivanti_iface || true)"
    fullvpn_if="$(fullvpn_default_route || true)"

    # 1. en0 が HPC4 と同 /16 → LAN 直結が下回り。フル VPN 共存なら pf anchor 要
    if [[ -n "$en0_ip" ]] && is_in_hpc4_subnet "$en0_ip"; then
        if [[ -n "$fullvpn_if" ]]; then
            echo "ng:fullvpn-hijack:iface=${fullvpn_if}"
            return 1
        fi
        echo "ok:lan-reach:en0_ip=${en0_ip}"
        return 0
    fi
    # 2. Ivanti split-tunnel が下回り。フル VPN 共存なら pf anchor 要
    if [[ -n "$ivanti_if" ]]; then
        if [[ -n "$fullvpn_if" ]]; then
            echo "ng:fullvpn-hijack:iface=${fullvpn_if}"
            return 1
        fi
        echo "ok:vpn-tunnel:iface=${ivanti_if}"
        return 0
    fi
    # 3. en0 ゲートウェイも Ivanti も無い → そもそもネット未接続
    if [[ -z "$en0_gw" ]]; then
        echo "ng:no-route"
        return 1
    fi
    # 4. en0 はあるが HKUST 圏外 + Ivanti 無し → HPC4 不通で確定
    #    （フル VPN の有無は無関係。pf anchor では HKUST へ届く経路は作れない）
    echo "ng:no-reach:en0_ip=${en0_ip:-?}"
    return 1
}

# classify_network の verdict 文字列を人間向けの 1 行診断に整形して出力。
# ng の場合は具体的な救済アクションも文末に含める。
render_network_verdict() {
    local verdict="$1"
    local rest="${verdict#*:}"
    local kind="${rest%%:*}"
    local detail=""
    if [[ "$rest" == *:* ]]; then
        detail="${rest#*:}"
    fi

    case "$kind" in
        lan-reach)
            printf "  [ok]   HPC4 到達性: 同 LAN 直結 (%s)\n" "$detail"
            ;;
        vpn-tunnel)
            printf "  [ok]   HPC4 到達性: split-tunnel VPN 経由 (%s)\n" "$detail"
            ;;
        fullvpn-hijack)
            printf "  [ng]   HPC4 到達性: default route が他 VPN (%s) に奪取 → scripts/net-up.sh で pf anchor 例外を適用してください\n" "$detail"
            ;;
        no-reach)
            printf "  [ng]   HPC4 到達性: 不通 (%s) → Ivanti Secure Access を起動するか eduroam/HKUST 有線に接続してください\n" "$detail"
            ;;
        no-route)
            printf "  [ng]   HPC4 到達性: 経路候補なし → eduroam / HKUST 有線 / Ivanti のいずれかに接続してください\n"
            ;;
        *)
            printf "  [?]    HPC4 到達性: 分類不能 (%s)\n" "$verdict"
            ;;
    esac
}

# --- SSH ラッパ用ヘルパ -----------------------------------------------------
# NOTE: macOS 既定 bash 3.2 互換のため mapfile / nameref は使わない。
# 共通オプションは配列 HPC4_SSH_OPTS にセットする（source 時に構築）。

build_ssh_opts() {
    HPC4_SSH_OPTS=(-F "$SSH_CONFIG")
    if [[ -n "${HPC4_USER:-}" ]]; then
        HPC4_SSH_OPTS+=(-l "$HPC4_USER")
    fi
    if [[ -n "${HPC4_IDENTITY_FILE:-}" ]]; then
        HPC4_SSH_OPTS+=(-i "$HPC4_IDENTITY_FILE" -o IdentitiesOnly=yes)
    fi
}
build_ssh_opts

# ControlMaster ソケットが生きているか
cm_alive() {
    require_user_conf
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O check hpc4 2>/dev/null
}

# passwordless SSH が通るか（BatchMode で true を走らせる）
ssh_passwordless_ok() {
    require_user_conf
    ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 hpc4 true 2>/dev/null
}
