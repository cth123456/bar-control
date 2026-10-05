#!/bin/zsh
set -euo pipefail

# 编译并运行「03-C 定向复现」：第二次点「收编」必须一个字都不写。
#
# 判据（每条都印绝对路径 + mtime + sha256）：
#   ① 第一次点击确实收编并写盘（方案非空 → 允许写）
#   ② 第二次点击：config / router-adoptions.json / router-backups 三者的 mtime + sha 全不变
#   ③ 第二次点击的回执不许出现「已收编」
#   ④ 换「全部范围」再点一次，同样一个字都不许写
#   ⑤ 收尾：真目录逐项与开工时相同（连 config-backups / backups 子目录清单一起比）
#
# 安全边界：真目录只读；写盘只落在 $TMPDIR 的配置副本里（LOCAL_SIRI_ROUTER_CONFIG 指过去）。
#
#   Tools/verify-reentry-paths.command          # 跑一遍
#   Tools/verify-reentry-paths.command --keep   # 保留沙箱目录，便于自己再翻

project_dir=${0:A:h:h}
out=${TMPDIR:-/tmp}/verify-reentry-paths

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

build_dir=${TMPDIR:-/tmp}/verify-reentry-paths-build
rm -rf "$build_dir"
mkdir -p "$build_dir"
cp "$project_dir"/Tools/verify-reentry-paths.swift "$build_dir"/main.swift

/usr/bin/swiftc -swift-version 5 \
    -framework AppKit -framework AVFoundation -framework SwiftUI \
    "${plugin_args[@]}" \
    "$project_dir"/Sources/HubAgentSync.swift \
    "$project_dir"/Sources/HubClients.swift \
    "$project_dir"/Sources/HubCodexCatalogSync.swift \
    "$project_dir"/Sources/HubModel.swift \
    "$project_dir"/Sources/HubPages.swift \
    "$project_dir"/Sources/HubReceiptViews.swift \
    "$project_dir"/Sources/HubStrategySync.swift \
    "$project_dir"/Sources/HubWindow.swift \
    "$project_dir"/Sources/RouterManager.swift \
    "$project_dir"/Sources/VoicePopover.swift \
    "$build_dir"/main.swift \
    -o "$out"

"$out" "$@"
