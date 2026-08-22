#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
SOURCE_APP="$PROJECT_DIR/dist/Bar Control.app"
TARGET_APP="/Applications/Bar Control.app"

"$PROJECT_DIR/build.command"
/usr/bin/pkill -x CodexTouchBarNative 2>/dev/null || true
/bin/sleep 1
/bin/rm -rf "$TARGET_APP"
/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$TARGET_APP"
/usr/bin/open -n "$TARGET_APP"

echo "已安装并启动：$TARGET_APP"
