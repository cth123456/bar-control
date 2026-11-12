#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
PRODUCT_NAME="Bar Control"
APP_BUNDLE="$PROJECT_DIR/dist/$PRODUCT_NAME.app"
SIGN_IDENTITY=${SIGN_IDENTITY:--}
CLOUDKIT_PROFILE=${CLOUDKIT_PROFILE:-}
PRIVATE_BUILD_ENV="$PROJECT_DIR/.signing/build.env"
[[ -f "$PRIVATE_BUILD_ENV" ]] && source "$PRIVATE_BUILD_ENV"
ENTITLEMENTS_PATH=${BARCONTROL_ENTITLEMENTS:-"$PROJECT_DIR/.signing/BarControl.entitlements"}

if [[ -z "$CLOUDKIT_PROFILE" && -f "$PROJECT_DIR/.signing/BarControlCloudKit.provisionprofile" ]]; then
    CLOUDKIT_PROFILE="$PROJECT_DIR/.signing/BarControlCloudKit.provisionprofile"
fi
if [[ "$SIGN_IDENTITY" == "-" && -n "$CLOUDKIT_PROFILE" ]]; then
    SIGN_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')
fi

cd "$PROJECT_DIR"
/usr/bin/swift build -c release
BUILD_BIN_PATH=$(/usr/bin/swift build -c release --show-bin-path)

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$PROJECT_DIR/.build/release/CodexTouchBarNative" "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative"
/usr/bin/ditto "$BUILD_BIN_PATH/CodexTouchBarNative_CodexTouchBarNative.bundle" "$APP_BUNDLE/Contents/Resources/CodexTouchBarNative_CodexTouchBarNative.bundle"
/usr/bin/ditto "$PROJECT_DIR/.build/release/BarControlPowerHelper" "$APP_BUNDLE/Contents/MacOS/barcontrol-power-helper"
/usr/bin/ditto "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ -n "${BARCONTROL_CLOUDKIT_CONTAINER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :BarControlCloudKitContainerIdentifier string $BARCONTROL_CLOUDKIT_CONTAINER" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :BarControlCloudKitContainerIdentifier $BARCONTROL_CLOUDKIT_CONTAINER" "$APP_BUNDLE/Contents/Info.plist"
fi
/usr/bin/ditto "$PROJECT_DIR/Resources" "$APP_BUNDLE/Contents/Resources"
"$PROJECT_DIR/../../scripts/compile-app-icon.command" \
    "$PROJECT_DIR/Resources/BarControl.icns" \
    "13.0" \
    "$APP_BUNDLE/Contents/Resources"
/bin/chmod +x "$APP_BUNDLE/Contents/MacOS/CodexTouchBarNative" "$APP_BUNDLE/Contents/MacOS/barcontrol-power-helper" "$APP_BUNDLE/Contents/Resources/codex_touchbar.py"
if [[ -n "$CLOUDKIT_PROFILE" && -f "$CLOUDKIT_PROFILE" && -f "$ENTITLEMENTS_PATH" && "$SIGN_IDENTITY" != "-" ]]; then
    /usr/bin/ditto "$CLOUDKIT_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    /usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

# The power helper must run as root from a shell, where the hardened runtime
# without matching entitlements gets it SIGKILLed. Re-sign just that binary
# without the runtime flag; the app bundle's own signature stays untouched.
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/barcontrol-power-helper"

echo "$APP_BUNDLE"
