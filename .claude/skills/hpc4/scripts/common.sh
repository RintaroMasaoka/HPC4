#!/bin/bash
# 共通定数とヘルパー。他スクリプトから source される。
#
# このスキルは HPC4 (143.89.184.3) への host route 一点だけを管理する。
# default route や Claude 経路には絶対に触らない（破綻すると user が私に相談できなくなる）。
# VPN 製品の判別もしない。kernel の routing table に「143.89/16 を持つ IF」が
# あるか無いか、それだけで判断する。

set -u

# --- グループ共通の固定パラメータ -------------------------------------------
HPC4_HOST="hpc4.ust.hk"
HPC4_IP="143.89.184.3"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${SKILL_DIR}/ssh_config"
USER_CONF="${SKILL_DIR}/user.conf.local"

# --- 個人設定の読み込み -----------------------------------------------------
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

# --- ログ出力 ---------------------------------------------------------------
log()  { printf "[hpc4] %s\n" "$*"; }
ok()   { printf "[hpc4][ok] %s\n" "$*"; }
warn() { printf "[hpc4][warn] %s\n" "$*" >&2; }
err()  { printf "[hpc4][err] %s\n" "$*" >&2; }

# --- HPC4 への到達性判定 ---------------------------------------------------

# kernel に HPC4 をどの IF に出すか聞く。出力 1 行：「<iface> [<gateway>]」
# gateway が無い／link-local の場合は iface のみ返す。kernel が答えない場合は空。
hpc4_route_resolve() {
    route get "$HPC4_IP" 2>/dev/null | awk '
        /interface:/ {iface=$2}
        /gateway:/   {gw=$2}
        END {
            if (!iface) exit
            if (gw && gw !~ /^link#/) print iface, gw
            else                       print iface
        }
    '
}

# 与えた IF が 143.89/16 の IPv4 を持っているか（= HKUST 圏に居る or HKUST tunnel が立っている証拠）
iface_has_hkust_ip() {
    [[ -n "${1:-}" ]] || return 1
    ifconfig "$1" 2>/dev/null | awk '/inet 143\.89\./{found=1} END{exit !found}'
}

# 全 IF を走査して 143.89/16 IPv4 を持つ最初の IF 名を返す（無ければ空文字）。
# routing table と独立に「この Mac には HKUST 圏に届く能力があるか」を判定する。
# stale な host pin が route get の結果を歪めても、これは騙されない。
find_hkust_iface() {
    ifconfig 2>/dev/null | awk '
        /^[a-z]/ { iface=$1; sub(":", "", iface) }
        /inet 143\.89\./ { print iface; exit }
    '
}

# 既存の HPC4 host route が指す IF（無ければ空）
current_hpc4_iface() {
    netstat -rn 2>/dev/null | awk -v ip="$HPC4_IP" '$1==ip {print $NF; exit}'
}

# TCP 22 が通るか（タイムアウト秒、既定 5）
# macOS 既定 nc は BSD 系で -G が connect timeout、-w が overall I/O timeout
tcp22_ok() {
    local t="${1:-5}"
    nc -z -G "$t" -w "$t" "$HPC4_IP" 22 >/dev/null 2>&1
}

# ping で疎通確認（タイムアウト秒、既定 2）
ping_ok() {
    local t="${1:-2}"
    ping -c 2 -W "${t}000" "$HPC4_IP" >/dev/null 2>&1
}

# --- SSH ラッパ用ヘルパ -----------------------------------------------------
# macOS 既定 bash 3.2 互換のため mapfile / nameref は使わない

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

cm_alive() {
    require_user_conf
    ssh -F "$SSH_CONFIG" -l "$HPC4_USER" -O check hpc4 2>/dev/null
}

ssh_passwordless_ok() {
    require_user_conf
    ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 hpc4 true 2>/dev/null
}
