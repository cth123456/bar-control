#!/bin/zsh
set -euo pipefail

# 编译并运行路由器模型池核对脚本。
# 链接 Sources/ 里的真实数据层，所以打印出来的就是 ① ② ③ ④ 四块页面会显示的内容；
# 默认不改本机配置：收编演练跑在配置副本上，跑完还原并逐键比对。
#
#   Tools/verify-router-pool.command             # 只读：四块页面 + 收编方案 + 页面验收清单
#   Tools/verify-router-pool.command --choose    # 交互：选中某些组后页面会变成什么样（只算）
#   Tools/verify-router-pool.command --sandbox   # 演练：副本上真的收编→逐键比对→还原→逐字节比对
#
# 注意：这个工具不提供「真改本机配置」的模式，三种模式都只读真实配置、只写临时副本。

project_dir=${0:A:h:h}
out=${TMPDIR:-/tmp}/verify-router-pool

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
# （不这么做会报 "statements are not allowed at the top level"。）
build_dir=${TMPDIR:-/tmp}/verify-router-pool-build
rm -rf "$build_dir"
mkdir -p "$build_dir"
cp "$project_dir"/Tools/verify-router-pool.swift "$build_dir"/main.swift

# 注意带上 HubCodexCatalogSync.swift：HubClients / HubModel 会用到它。
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
