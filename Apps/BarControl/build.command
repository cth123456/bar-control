#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
PRODUCT_NAME="Bar Control"
APP_BUNDLE="$PROJECT_DIR/dist/$PRODUCT_NAME.app"
SIGN_IDENTITY=${SIGN_IDENTITY:--}
CLOUDKIT_PROFILE=${CLOUDKIT_PROFILE:-}
ENTITLEMENTS_PATH="$PROJECT_DIR/BarControl.entitlements"

if [[ -z "$CLOUDKIT_PROFILE" && -f "$PROJECT_DIR/.signing/BarControlCloudKit.provisionprofile" ]]; then
    CLOUDKIT_PROFILE="$PROJECT_DIR/.signing/BarControlCloudKit.provisionprofile"
fi
if [[ "$SIGN_IDENTITY" == "-" && -n "$CLOUDKIT_PROFILE" ]]; then
    SIGN_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')
fi

cd "$PROJECT_DIR"
/usr/bin/swift build -c release

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$PROJECT_DIR/.build/release/CodexTouchBarNative" "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative"
/usr/bin/ditto "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/ditto "$PROJECT_DIR/Resources" "$APP_BUNDLE/Contents/Resources"
"$PROJECT_DIR/../../scripts/compile-app-icon.command" \
    "$PROJECT_DIR/Resources/BarControl.icns" \
    "13.0" \
    "$APP_BUNDLE/Contents/Resources"
/bin/chmod +x "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative" "$APP_BUNDLE/Contents/Resources/codex_touchbar.py"
if [[ -n "$CLOUDKIT_PROFILE" && -f "$CLOUDKIT_PROFILE" && "$SIGN_IDENTITY" != "-" ]]; then
    /usr/bin/ditto "$CLOUDKIT_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    /usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
