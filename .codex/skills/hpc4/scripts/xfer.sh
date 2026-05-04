#!/bin/bash
# File transfer to/from HPC4.
#   ./xfer.sh put <local-path> <remote-path>    # local -> HPC4
#   ./xfer.sh get <remote-path> <local-path>    # HPC4 -> local
#
# remote-path can be "/home/<user>/...", "/scratch/<user>/...", "~/...", etc.
# Directory transfers go through rsync (faster); use put-r / get-r.

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

usage() {
    cat >&2 <<EOF
Usage:
  xfer.sh put <local> <remote>             local -> HPC4
  xfer.sh get <remote> <local>             HPC4 -> local
  xfer.sh put-r <local-dir> <remote-dir>   directory upload (rsync)
  xfer.sh get-r <remote-dir> <local-dir>   directory download (rsync)
EOF
    exit 2
}

[[ $# -ge 3 ]] || usage

op="$1"; src="$2"; dst="$3"

if ! tcp22_ok; then
    log "SSH route not ready. Running net-up.sh"
    bash "$(dirname "$0")/net-up.sh" || exit $?
fi

# rsync's --rsh receives one string.
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
