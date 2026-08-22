#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h}

"$repo_dir/scripts/generate-icons.command"
"$repo_dir/Apps/BarControl/build.command"
"$repo_dir/Apps/SidecarPilot/Scripts/build.sh"
"$repo_dir/Apps/LocalModelVoice/build.command"

echo "三款 App 均已构建完成。"
