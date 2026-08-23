#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
source_app=$($project_dir/Scripts/build.sh)
target_app="/Applications/随航管家.app"

/usr/bin/pkill -x SidecarPilot 2>/dev/null || true
/bin/rm -rf "$target_app"
/usr/bin/ditto --rsrc --extattr "$source_app" "$target_app"
/usr/bin/touch "$target_app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$lsregister" -f "$target_app"

echo "已安装：$target_app"
