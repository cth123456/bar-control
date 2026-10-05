#!/bin/zsh
set -euo pipefail

# 编译并运行「收编合同」独立验收器。
#
# 与官方 verify-router-pool.command 的分工：官方管整体演练（四块页面 · 数字自洽 · 全部范围），
# 这里专管它还没形成判据的那几条：复用不许动用户已有连接 · 台账不许记别人的连接 ·
# 被改指的行要记进台账并逐键还原 · 写盘前先备份 · 再点一次不重复建连接 ·
# 只读动作不写盘 · 台账 v1 仍要能读 · 验收项不许靠改阈值哄过去。
#
# 安全边界：只读真实配置，所有动作都在配置副本里做，真实目录一个字节都不碰。
#
#   Tools/verify-adopt-safety.command             # 全部判据
#   Tools/verify-adopt-safety.command --case A    # 只跑某一条（A / G / R / H / D）
#   Tools/verify-adopt-safety.command --keep      # 保留沙箱目录，便于自己再翻

project_dir=${0:A:h:h}
out=${TMPDIR:-/tmp}/verify-adopt-safety

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

# swiftc 只让「名叫 main.swift 的那个文件」带顶层语句，所以先把工具源码拷成 main.swift 再编。
build_dir=${TMPDIR:-/tmp}/verify-adopt-safety-build
rm -rf "$build_dir"
mkdir -p "$build_dir"
cp "$project_dir"/Tools/verify-adopt-safety.swift "$build_dir"/main.swift

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
