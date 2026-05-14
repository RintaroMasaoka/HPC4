#!/bin/bash
# ssh wrapper invoked by `rsync -e`.
# Just exec ssh while expanding HPC4_SSH_OPTS (-F <ssh_config> -l <user>
# [-i <key> -o IdentitiesOnly=yes]) as a real array.
# Keep rsync on the same non-interactive auth contract as ssh-run.sh/scp:
# if passwordless SSH is not ready, fail instead of waiting for passphrase input.
#
# Why: rsync's -e takes a single string, so when SSH_CONFIG contains spaces
# either printf '%q' or shell-style quoting still has corner-case bugs. Pinning
# this to a one-purpose wrapper script is the most robust fix.
set -u
source "$(dirname "$0")/common.sh"
require_user_conf
exec ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes "$@"
