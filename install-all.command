#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h}

"$repo_dir/scripts/generate-icons.command"
"$repo_dir/Apps/SidecarPilot/install.command"
"$repo_dir/Apps/LocalModelVoice/install.command"
"$repo_dir/Apps/BarControl/install.command"

echo "Bar Control 套件已安装。"
