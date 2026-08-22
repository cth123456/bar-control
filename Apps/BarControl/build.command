#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
PRODUCT_NAME="Bar Control"
APP_BUNDLE="$PROJECT_DIR/dist/$PRODUCT_NAME.app"
SIGN_IDENTITY=${SIGN_IDENTITY:--}

cd "$PROJECT_DIR"
/usr/bin/swift build -c release

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$PROJECT_DIR/.build/release/CodexTouchBarNative" "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative"
/usr/bin/ditto "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/ditto "$PROJECT_DIR/Resources" "$APP_BUNDLE/Contents/Resources"
/bin/chmod +x "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative" "$APP_BUNDLE/Contents/Resources/codex_touchbar.py"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "$APP_BUNDLE"
