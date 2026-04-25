#!/bin/bash
# user.conf.local を機械的に書き出す。
#   ./write-user-conf.sh <username> [account] [partition] [identity_file]
# 既存ファイルは上書きされるので注意。通常は Claude が setup フロー内で呼ぶ。

set -u
source "$(dirname "$0")/common.sh"

username="${1:-}"
account="${2:-watanabemc}"
partition="${3:-amd}"
identity_file="${4:-}"

if [[ -z "$username" ]]; then
    err "Usage: write-user-conf.sh <username> [account] [partition] [identity_file]"
    exit 2
fi

cat > "$USER_CONF" <<EOF
# HPC4 個人設定。setup フローで自動生成。手で書き換えてもよい。
# このファイルは .gitignore 済み（リポジトリには含まれない）。

HPC4_USER="${username}"
HPC4_ACCOUNT="${account}"
HPC4_PARTITION="${partition}"
HPC4_IDENTITY_FILE="${identity_file}"
EOF

ok "書き出し完了: $USER_CONF"
printf "  HPC4_USER=%s\n  HPC4_ACCOUNT=%s\n  HPC4_PARTITION=%s\n  HPC4_IDENTITY_FILE=%s\n" \
    "$username" "$account" "$partition" "$identity_file"
