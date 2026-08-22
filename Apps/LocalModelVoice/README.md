# 本地模型语音助手

Touch Bar 上的可选语音入口：音频与 Whisper 转写留在本机，Ollama 处理简单任务；需要实时信息、来源或复杂工具能力时，才把转写后的文字交给用户配置的云端 CLI。音频不会上传。

## 依赖

- macOS 14 或更高版本
- [Ollama](https://ollama.com/) 与 `qwen3.5:4b`
- `whisper-cpp` 及 `ggml-small.bin`
- 系统设置中已下载的高质量普通话 `Linfei` 声音
- 可选：已登录的 Codex CLI，用于处理需要云端能力的问题

## 安装

```sh
brew install whisper-cpp
ollama pull qwen3.5:4b
ollama create local-siri-qwen -f Resources/Modelfile
mkdir -p "$HOME/Library/Application Support/LocalSiriLLM/models"
curl -L \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
  -o "$HOME/Library/Application Support/LocalSiriLLM/models/ggml-small.bin"
./install.command
```

首次使用时，macOS 会请求麦克风权限。默认云端配置从 `PATH` 调用 Codex CLI，并使用只读沙箱；可复制并修改 `Resources/cloud-provider.example.json`。

## 验证

```sh
/usr/bin/python3 \
  "$HOME/Library/Application Support/LocalSiriLLM/local_assistant.py" \
  --doctor
```

语音状态通过 `~/Library/Application Support/LocalSiriLLM/touchbar-state.tsv` 提供给 Bar Control；处理过程中再次点击语音模块会取消当前任务并清理临时录音。
