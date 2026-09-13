#!/bin/zsh
# 卸载「优先放电」辅助组件：先恢复充电器，再删除特权文件与 sudoers 白名单。
set -euo pipefail

TARGET=/Library/PrivilegedHelperTools/barcontrol-power-helper
SUDOERS_FILE=/etc/sudoers.d/barcontrol-power-helper

echo "== 1/2 恢复充电器（若曾断开） =="
if [[ -x "$TARGET" ]]; then
    sudo -n "$TARGET" discharge off || sudo "$TARGET" discharge off || true
fi

echo "== 2/2 删除特权文件与白名单 =="
sudo /bin/rm -f "$TARGET" "$SUDOERS_FILE"
echo "已卸载。Bar Control 的「优先放电」将退回系统充电上限行为。"
