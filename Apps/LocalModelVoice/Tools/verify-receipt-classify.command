#!/bin/zsh
set -euo pipefail

# 编译并运行「拦截页不再判死」的证据表：旧红在哪几条上变绿、有没有哪条真红被悄悄放行。
#
# 判据（见 Tools/verify-receipt-classify.swift 头部）：
#   ① 除 401 / 403 外的码一条没变
#   ② 旧红 → 新绿的样本逐条印出，每条必须逐字命中拦截页特征词（硬 / 软分开印）
#   ③ 不存在「旧绿 → 新红」（这次改动不新增黑名单）
#   ④ 干净 JSON 的 401 / 403（真钥匙被拒 / 真没权限）仍然判死
#   ⑤ 9 个类别的 shortReason / nextStep 都是人话
#   ⑥ 「被网关挡下」这一类明细里写出判定依据；只命中软特征的不用确定口吻
#   ⑦ 工具的特征表与 App 里的 `gatewayBlockEvidence` 逐条一致（不是两套判据各说各话）
#   ⑧ 真实 router-stats.json 里旧红的每一条，要么新仍红，要么原文命中拦截页特征
#
# 安全边界：只读。不写配置、不碰网络，读的只有网关自己写的 router-stats.json。
#
#   Tools/verify-receipt-classify.command          # 跑一遍
#   Tools/verify-receipt-classify.command --json   # 额外打一行 JSON 结论

project_dir=${0:A:h:h}
out=${TMPDIR:-/tmp}/verify-receipt-classify

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

build_dir=${TMPDIR:-/tmp}/verify-receipt-classify-build
rm -rf "$build_dir"
mkdir -p "$build_dir"
cp "$project_dir"/Tools/verify-receipt-classify.swift "$build_dir"/main.swift

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
