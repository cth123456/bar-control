#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
app_dir="$build_dir/随航管家.app"
sign_identity=${SIGN_IDENTITY:--}

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -swift-version 5 -O -framework AppKit \
  "$project_dir/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/SidecarPilot"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/connect-sidecar.applescript" "$app_dir/Contents/Resources/connect-sidecar.applescript"
cp "$project_dir/Resources/SidecarPilot.icns" "$app_dir/Contents/Resources/SidecarPilot.icns"
"$project_dir/../../scripts/compile-app-icon.command" \
  "$project_dir/Resources/SidecarPilot.icns" \
  "13.0" \
  "$app_dir/Contents/Resources"
codesign --force --deep --sign "$sign_identity" "$app_dir"
echo "$app_dir"
