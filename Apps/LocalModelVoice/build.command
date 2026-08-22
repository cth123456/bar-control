#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/.build/本地模型.app"
sign_identity=${SIGN_IDENTITY:--}

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O \
    -framework AppKit \
    -framework AVFoundation \
    "$project_dir/Sources/LocalModelVoice.swift" \
    -o "$app_dir/Contents/MacOS/LocalModelVoice"
/usr/bin/ditto "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/ditto "$project_dir/Resources/LocalModelVoice.icns" "$app_dir/Contents/Resources/LocalModelVoice.icns"
/usr/bin/codesign --force --deep --sign "$sign_identity" "$app_dir"

echo "$app_dir"
