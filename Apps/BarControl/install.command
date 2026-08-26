#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
SOURCE_APP="$PROJECT_DIR/dist/Bar Control.app"
TARGET_APP="/Applications/Bar Control.app"
SIGNING_PROFILE="$PROJECT_DIR/.signing/BarControlCloudKit.provisionprofile"

if [[ -f "$SIGNING_PROFILE" ]]; then
    SIGN_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')
    if [[ -n "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$SIGN_IDENTITY" CLOUDKIT_PROFILE="$SIGNING_PROFILE" "$PROJECT_DIR/build.command"
    else
        echo "CloudKit 描述文件存在，但没有找到有效的 Apple Development 证书。" >&2
        exit 1
    fi
else
    "$PROJECT_DIR/build.command"
fi
/usr/bin/pkill -x CodexTouchBarNative 2>/dev/null || true
/bin/sleep 1
/bin/rm -rf "$TARGET_APP"
/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$TARGET_APP"
/usr/bin/touch "$TARGET_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET_APP"
/usr/bin/open -n "$TARGET_APP"

echo "已安装并启动：$TARGET_APP"
