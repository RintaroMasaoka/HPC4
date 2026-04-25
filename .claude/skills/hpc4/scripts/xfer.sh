#!/bin/bash
# HPC4 とのファイル転送。
#   ./xfer.sh put <local-path> <remote-path>    # ローカル → HPC4
#   ./xfer.sh get <remote-path> <local-path>    # HPC4 → ローカル
#
# remote-path は "/home/<user>/...", "/scratch/<user>/...", "~/..." などを書ける。
# ディレクトリ転送は rsync の方が速いので、-r が付いている場合は rsync を使う。

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

usage() {
    cat >&2 <<EOF
Usage:
  xfer.sh put <local> <remote>    ローカル → HPC4
  xfer.sh get <remote> <local>    HPC4 → ローカル
  xfer.sh put-r <local-dir> <remote-dir>   ディレクトリアップロード（rsync）
  xfer.sh get-r <remote-dir> <local-dir>   ディレクトリダウンロード（rsync）
EOF
    exit 2
}

[[ $# -ge 3 ]] || usage

op="$1"; src="$2"; dst="$3"

if ! ping_ok 2; then
    log "経路未整備。net-up.sh を実行"
    bash "$(dirname "$0")/net-up.sh" || exit $?
fi

# rsync の --rsh="ssh ..." に渡すための 1 行
rsh_opts="$(printf '%q ' "${HPC4_SSH_OPTS[@]}")"

case "$op" in
    put)
        exec scp "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes "$src" "hpc4:$dst"
        ;;
    get)
        exec scp "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes "hpc4:$src" "$dst"
        ;;
    put-r)
        exec rsync -avz --progress -e "ssh ${rsh_opts}" "$src/" "hpc4:$dst/"
        ;;
    get-r)
        exec rsync -avz --progress -e "ssh ${rsh_opts}" "hpc4:$src/" "$dst/"
        ;;
    *)
        usage
        ;;
esac
