#!/bin/zsh
set -euo pipefail

# 编译并运行无界面核对脚本（只读，不写配置）。
# 它链接的是 Sources/ 里的真实数据层，所以打印出来的就是 Agent 页会显示的内容。

project_dir=${0:A:h:h}
out=${TMPDIR:-/tmp}/verify-agent-switch

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

# 除入口文件 LocalModelVoice.swift 之外的全部源码：核对脚本自己当 main。
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
    "$project_dir"/Tools/verify-agent-switch.swift \
    -o "$out"

"$out"
