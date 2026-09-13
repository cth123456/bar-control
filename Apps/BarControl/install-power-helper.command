#!/bin/zsh
# 安装「优先放电」辅助组件（一次性管理员密码）。
#
# 作用：把 barcontrol-power-helper 安装为 root 所有的特权 CLI，并写入
# /etc/sudoers.d 免密白名单，让 Bar Control 在选择「优先放电」时能断开
# 充电器（CHIE 键）让外接设备优先取电；切回其他策略或退出 App 时自动恢复。
#
# 可重复运行；卸载请用 uninstall-power-helper.command。
set -euo pipefail

PROJECT_DIR=${0:A:h}
SOURCE_HELPER="$PROJECT_DIR/dist/Bar Control.app/Contents/MacOS/barcontrol-power-helper"
TARGET_DIR=/Library/PrivilegedHelperTools
TARGET="$TARGET_DIR/barcontrol-power-helper"
SUDOERS_FILE=/etc/sudoers.d/barcontrol-power-helper

if [[ ! -x "$SOURCE_HELPER" ]]; then
    echo "没有找到辅助组件：$SOURCE_HELPER" >&2
    echo "请先运行同目录的 install.command（或 build.command）重新构建 App。" >&2
    exit 1
fi

echo "== 1/4 复制辅助组件到 $TARGET =="
sudo /bin/mkdir -p "$TARGET_DIR"
sudo /usr/bin/ditto "$SOURCE_HELPER" "$TARGET"
sudo /usr/sbin/chown root:wheel "$TARGET"
sudo /bin/chmod 755 "$TARGET"
sudo /usr/bin/codesign --verify "$TARGET" >/dev/null 2>&1 \
    && echo "签名校验通过" \
    || echo "提示：辅助组件签名校验未通过（仍可继续，仅影响公证）"

echo "== 2/4 写入 sudoers 免密白名单 =="
TMP_SUDOERS=$(/usr/bin/mktemp)
trap '/bin/rm -f "$TMP_SUDOERS"' EXIT
cat > "$TMP_SUDOERS" <<'EOF'
# Bar Control 放电辅助组件：只允许下面这些固定命令免密执行。
Cmnd_Alias BARCONTROL_POWER_WRITE = /Library/PrivilegedHelperTools/barcontrol-power-helper discharge on, /Library/PrivilegedHelperTools/barcontrol-power-helper discharge off
Cmnd_Alias BARCONTROL_POWER_READ = /Library/PrivilegedHelperTools/barcontrol-power-helper status, /Library/PrivilegedHelperTools/barcontrol-power-helper probe
ALL ALL = NOPASSWD: BARCONTROL_POWER_WRITE, BARCONTROL_POWER_READ
EOF
sudo /usr/sbin/visudo -c -f "$TMP_SUDOERS"
sudo /usr/bin/install -m 440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS_FILE"

echo "== 3/4 自检：读取当前充电器状态 =="
sudo -n "$TARGET" status || true

echo "== 4/4 权限探测：把当前值写回（不改变状态）=="
if sudo -n "$TARGET" probe; then
    echo "写入路径可用：现在可以在 Bar Control 菜单里选择「优先放电」。"
else
    echo "写入被系统拒绝（上面有输出）：说明这版 macOS 固件已门控 CHIE 键。" >&2
    echo "「优先放电」仍会退回到系统充电上限 80% 的行为，不会造成其他影响。" >&2
fi

echo "完成。选择「优先充电/负载均衡」或退出 App 时会自动恢复充电器。"
