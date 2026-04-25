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
        printf "[hpc4][err] %s\n" "個人設定 ${USER_CONF} がありません。'/hpc4 setup' を実行してください。" >&2
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
tcp22_ok() {
    # /dev/tcp は bash 組み込み、外部コマンド不要。タイムアウトのため & + kill で囲む
    ( exec 3<>/dev/tcp/"$HPC4_IP"/22 ) >/dev/null 2>&1 &
    local pid=$!
    ( sleep 5; kill "$pid" 2>/dev/null ) &
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
