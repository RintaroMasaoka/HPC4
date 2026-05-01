#!/bin/bash
# HPC4 上で任意のコマンドを実行する。
#   ./ssh-run.sh "<command>"
# 経路が未整備なら net-up.sh を呼んで HPC4 host route を pin する。
# 認証は passwordless SSH（要 setup 済）。ControlMaster で 2 回目以降は即レス。

set -u
source "$(dirname "$0")/common.sh"
require_user_conf

if [[ $# -lt 1 ]]; then
    err "Usage: ssh-run.sh \"<command to run on HPC4>\""
    exit 2
fi

# ネットワーク層が未整備なら整備（既に届くならスキップ）
# ICMP は eduroam でブロックされる場合があるため TCP 22 で到達確認する
if ! tcp22_ok 3; then
    log "経路未整備。net-up.sh を実行"
    bash "$(dirname "$0")/net-up.sh" || exit $?
fi

exec ssh "${HPC4_SSH_OPTS[@]}" -o BatchMode=yes hpc4 "$@"
