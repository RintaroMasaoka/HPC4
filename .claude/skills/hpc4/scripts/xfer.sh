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

if ! tcp22_ok 1; then
    log "Route not yet ready. Running net-up.sh"
    bash "$(dirname "$0")/net-up.sh" || exit $?
fi

# rsync's -e is a single string, so quoting bugs creep in if SSH_CONFIG has
# spaces. Confine HPC4_SSH_OPTS expansion to ssh-wrap.sh.
# The wrapper path itself may also contain spaces, so single-quote it as one token.
ssh_wrap="$(dirname "$0")/ssh-wrap.sh"

case "$op" in
    put)
        exec scp "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes "$src" "hpc4:$dst"
        ;;
    get)
        exec scp "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes "hpc4:$src" "$dst"
        ;;
    put-r)
        exec rsync -avz --progress -e "'$ssh_wrap'" "$src/" "hpc4:$dst/"
        ;;
    get-r)
        exec rsync -avz --progress -e "'$ssh_wrap'" "hpc4:$src/" "$dst/"
        ;;
    *)
        usage
        ;;
esac
