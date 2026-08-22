#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
asset_dir="$repo_dir/docs/assets"

/usr/bin/swift "$repo_dir/scripts/generate-icons.swift" "$asset_dir"
/usr/bin/sips -z 1024 1024 "$asset_dir/icon-bar-control.png" --out "$asset_dir/icon-bar-control.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$asset_dir/icon-sidecar-pilot.png" --out "$asset_dir/icon-sidecar-pilot.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$asset_dir/icon-local-model.png" --out "$asset_dir/icon-local-model.png" >/dev/null
/usr/bin/sips -z 36 36 "$asset_dir/bar-control-template.png" --out "$asset_dir/bar-control-template.png" >/dev/null

make_icns() {
    local source_png=$1
    local destination=$2
    local temp_dir
    temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bar-control-icons.XXXXXX")
    local iconset="$temp_dir/AppIcon.iconset"
    /bin/mkdir -p "$iconset"
    /usr/bin/sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
    /usr/bin/sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
    /usr/bin/sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
    /usr/bin/sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
    /usr/bin/sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
    /usr/bin/sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
    /usr/bin/sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
    /usr/bin/sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
    /usr/bin/sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
    /usr/bin/sips -z 1024 1024 "$source_png" --out "$iconset/icon_512x512@2x.png" >/dev/null
    /usr/bin/iconutil -c icns "$iconset" -o "$destination"
    /bin/rm -rf "$temp_dir"
}

/bin/mkdir -p \
    "$repo_dir/Apps/BarControl/Resources" \
    "$repo_dir/Apps/SidecarPilot/Resources" \
    "$repo_dir/Apps/LocalModelVoice/Resources"

make_icns "$asset_dir/icon-bar-control.png" "$repo_dir/Apps/BarControl/Resources/BarControl.icns"
make_icns "$asset_dir/icon-sidecar-pilot.png" "$repo_dir/Apps/SidecarPilot/Resources/SidecarPilot.icns"
make_icns "$asset_dir/icon-local-model.png" "$repo_dir/Apps/LocalModelVoice/Resources/LocalModelVoice.icns"
/usr/bin/ditto "$asset_dir/bar-control-template.png" "$repo_dir/Apps/BarControl/Resources/BarControlTemplate.png"

echo "已生成三款 App 图标。"
