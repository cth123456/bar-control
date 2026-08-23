#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
source_app=$($project_dir/build.command)
target_app="/Applications/本地模型.app"
support_dir="$HOME/Library/Application Support/LocalSiriLLM"

/usr/bin/pkill -x LocalModelVoice 2>/dev/null || true
/bin/rm -rf "$target_app"
/usr/bin/ditto --rsrc --extattr "$source_app" "$target_app"
/usr/bin/touch "$target_app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$lsregister" -f "$target_app"
/bin/mkdir -p "$support_dir"
/usr/bin/ditto "$project_dir/Resources/local_assistant.py" "$support_dir/local_assistant.py"
/usr/bin/ditto "$project_dir/Resources/SiriSpeechHelper.swift" "$support_dir/SiriSpeechHelper.swift"
if [[ ! -f "$support_dir/cloud-provider.json" ]]; then
    /usr/bin/ditto "$project_dir/Resources/cloud-provider.example.json" "$support_dir/cloud-provider.json"
fi
/bin/chmod +x "$support_dir/local_assistant.py"

echo "已安装：$target_app"
if [[ ! -f "$support_dir/models/ggml-small.bin" ]]; then
    echo "提示：尚未找到 Whisper small 模型，请按 README 完成本地语音运行环境。"
fi
