#!/bin/bash
# User-terminal entry point for net-up.sh.
#
# This wrapper is intentionally for a real local Terminal, not Codex automation:
# it allows sudo to prompt for the Mac login password or Touch ID when route/pf
# changes are needed.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export HPC4_ALLOW_INTERACTIVE_SUDO=1
exec bash "${SCRIPT_DIR}/net-up.sh"
