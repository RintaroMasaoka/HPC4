#!/bin/bash
# user の Terminal 専用 entry point。
#
# Claude/Codex 等の AI 実行からは sudo password / Touch ID を扱わない。
# route / pf 変更が必要な時だけ、この wrapper を user が自分の Terminal で実行する。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/net-up-local.sh"
exec bash "${SCRIPT_DIR}/net-up.sh"
