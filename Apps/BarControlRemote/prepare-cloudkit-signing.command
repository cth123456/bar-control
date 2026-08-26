#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
BAR_CONTROL_DIR="$PROJECT_DIR/../BarControl"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Users/mac/Downloads/Xcode-beta.app/Contents/Developer}
DERIVED_DIR=$(mktemp -d)
SIGNING_DIR="$BAR_CONTROL_DIR/.signing"

cd "$PROJECT_DIR"
/opt/homebrew/bin/xcodegen generate
DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcodebuild \
    -project BarControlRemote.xcodeproj \
    -scheme BarControlCloudProvisioning \
    -configuration Debug \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DIR" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build

PROFILE="$DERIVED_DIR/Build/Products/Debug/Bar Control Provisioning.app/Contents/embedded.provisionprofile"
if [[ ! -f "$PROFILE" ]]; then
    echo "没有生成 Mac CloudKit 描述文件，请先在 Xcode → Settings → Accounts 重新登录 Apple 开发者账号。" >&2
    exit 1
fi

SIGN_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "没有找到有效的 Apple Development 签名证书。" >&2
    exit 1
fi

/bin/mkdir -p "$SIGNING_DIR"
/usr/bin/ditto "$PROFILE" "$SIGNING_DIR/BarControlCloudKit.provisionprofile"
SIGN_IDENTITY="$SIGN_IDENTITY" \
CLOUDKIT_PROFILE="$SIGNING_DIR/BarControlCloudKit.provisionprofile" \
    "$BAR_CONTROL_DIR/build.command"

echo "CloudKit 签名已准备：$BAR_CONTROL_DIR/dist/Bar Control.app"
