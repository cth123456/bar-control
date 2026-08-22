#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}

if /usr/bin/grep -RInE \
    --exclude-dir=.git \
    --exclude-dir=.build \
    --exclude-dir=dist \
    --exclude='*.png' \
    --exclude='*.icns' \
    --exclude='check-public-tree.command' \
    '(/Users/mac|CTHPAD|gho_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|chaitianhao@thb\.com\.cn)' \
    "$repo_dir"; then
    echo "发现不应公开的本机路径、设备名或凭据样式。" >&2
    exit 1
fi

echo "公开内容检查通过。"
