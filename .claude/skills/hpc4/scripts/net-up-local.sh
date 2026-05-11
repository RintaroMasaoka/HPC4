#!/bin/bash
# user の Terminal 専用 entry point。
#
# Claude/Codex 等の AI 実行からは sudo password / Touch ID を扱わない。
# route / pf 変更が必要な時だけ、この wrapper を user が自分の Terminal で実行する。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf "[hpc4][err] net-up-local.sh は sudo 認証が必要なため、対話ターミナルから実行してください。\n" >&2
        exit 2
    fi

    printf "[hpc4] sudo 認証を確認します（password / Touch ID が必要な場合があります）\n"
    if ! sudo -v; then
        printf "[hpc4][err] sudo 認証に失敗しました。認証を完了してから再実行してください。\n" >&2
        exit 2
    fi
fi

export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/net-up-local.sh"
exec bash "${SCRIPT_DIR}/net-up.sh"
