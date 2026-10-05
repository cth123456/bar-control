#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/.build/AI助手.app"
staging_dir="$project_dir/.build/AI助手.app.staging"
sign_identity=${SIGN_IDENTITY:--}

# SwiftUI 的 @State / @Observable 是编译期宏：Command Line Tools 的 toolchain 里不带这些插件，
# 需要借用 Xcode 平台目录里的插件，否则报 "plugin for module 'SwiftUIMacros' not found"。
plugin_args=()
for macro_plugin_dir in \
    "$(/usr/bin/xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins \
    /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins; do
    if [[ -f "$macro_plugin_dir/libSwiftUIMacros.dylib" ]]; then
        plugin_args=(-plugin-path "$macro_plugin_dir")
        break
    fi
done

# 先记下用户此刻是否开着 AI助手：下面会换掉整个 .app 包，macOS 随即把它注销再注册，
# 桌面上的图标与窗口会当场消失 —— 用户看到的「AI助手又没了」就是这么来的。
app_was_running=0
if /usr/bin/pgrep -f "$app_dir/Contents/MacOS/LocalModelVoice" >/dev/null 2>&1; then
    app_was_running=1
fi

# 先在旁边把新包完整做出来：编译一旦失败就到此为止，用户手里那个 App 一根汗毛都不动。
# 成功后再整体换上去（同卷 mv 是原子操作），从此不会再有「编译炸了、App 也没了」的半吊子状态。
# 中途任何一步失败（编译错、图标脚本报错…）都把半成品收干净；
# 换上去之后 staging 目录已经不存在，这条 trap 顺手变成空操作。
trap '/bin/rm -rf "$staging_dir"' EXIT

/bin/rm -rf "$staging_dir"
/bin/mkdir -p "$staging_dir/Contents/MacOS" "$staging_dir/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O \
    -framework AppKit \
    -framework AVFoundation \
    -framework SwiftUI \
    "${plugin_args[@]}" \
    "$project_dir"/Sources/*.swift \
    -o "$staging_dir/Contents/MacOS/LocalModelVoice"
/usr/bin/ditto "$project_dir/Info.plist" "$staging_dir/Contents/Info.plist"
/usr/bin/ditto "$project_dir/Resources/LocalModelVoice.icns" "$staging_dir/Contents/Resources/LocalModelVoice.icns"
"$project_dir/../../scripts/compile-app-icon.command" \
    "$project_dir/Resources/LocalModelVoice.icns" \
    "14.0" \
    "$staging_dir/Contents/Resources"

/bin/rm -rf "$app_dir"
/bin/mv "$staging_dir" "$app_dir"
/usr/bin/codesign --force --deep --sign "$sign_identity" "$app_dir"

# 构建前就在跑的：把它请回来（open 同时也会把新包重新注册进 LaunchServices）。
if [[ "$app_was_running" == 1 ]]; then
    /usr/bin/open "$app_dir"
fi

echo "$app_dir"
