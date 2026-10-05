#!/bin/zsh
set -euo pipefail

# install.command 现在装到 /Applications/AI助手.app；旧的「本地模型.app」只在
# 尚未重装过的机器上存在，作为兼容回退，避免这里写死旧路径后直接报错退出。
for app in "/Applications/AI助手.app" "/Applications/本地模型.app"; do
    if [[ -x "$app/Contents/MacOS/LocalModelVoice" ]]; then
        exec "$app/Contents/MacOS/LocalModelVoice" --manage
    fi
done

echo "尚未安装 AI助手.app，请先运行 install.command。"
exit 1
