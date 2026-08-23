#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
    echo "用法：$0 <icon.icns> <最低 macOS 版本> <Resources 目录>" >&2
    exit 64
fi

script_dir=${0:A:h}
icon_file=$1
minimum_target=$2
resources_dir=$3
work_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$work_dir"' EXIT

if ! /usr/bin/xcrun --find actool >/dev/null 2>&1; then
    xcode_app=$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' | /usr/bin/head -1)
    if [[ -z "$xcode_app" || ! -x "$xcode_app/Contents/Developer/usr/bin/actool" ]]; then
        echo "未找到完整 Xcode，无法生成 macOS 27 所需的 Assets.car。" >&2
        exit 69
    fi
    export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi

iconset_dir="$work_dir/source.iconset"
catalog_dir="$work_dir/AppAssets.xcassets"
appicon_dir="$catalog_dir/AppIcon.appiconset"
/bin/mkdir -p "$appicon_dir" "$resources_dir"
/usr/bin/iconutil -c iconset "$icon_file" -o "$iconset_dir"
/usr/bin/ditto "$iconset_dir" "$appicon_dir"
/usr/bin/ditto "$script_dir/AppIconContents.json" "$appicon_dir/Contents.json"

/usr/bin/xcrun actool \
    --compile "$resources_dir" \
    --platform macosx \
    --minimum-deployment-target "$minimum_target" \
    --app-icon AppIcon \
    --output-partial-info-plist "$work_dir/asset-info.plist" \
    "$catalog_dir" >/dev/null
