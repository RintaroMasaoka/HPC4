#!/bin/bash
# User-terminal entry point for net-down.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export HPC4_ALLOW_INTERACTIVE_SUDO=1
export HPC4_LOCAL_HELPER="${SCRIPT_DIR}/net-down-local.sh"
exec bash "${SCRIPT_DIR}/net-down.sh"
