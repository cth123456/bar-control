# AI助手

Touch Bar 上的可选语音入口：音频与 Whisper 转写留在本机，Ollama 处理简单任务；需要实时信息、来源或复杂工具能力时，才把转写后的文字交给用户配置的云端 CLI。音频不会上传。

本地分流分两级：普通问答、改写、总结走不带工具的快速路径（约 4–8 秒）；出现"提醒、打开、搜索、剪贴板、音量、系统状态"等可能要用工具的请求时，才装载工具定义走完整路径（约 15–25 秒）。工具定义约 950 token，是本地提示处理耗时的主要来源；Ollama 无前缀缓存，每次都要重新处理提示词，因此不必要时不装载。没有工具提示的请求可再经 Laya 本地预筛（见下）提前升级云端。

Whisper 在多语言 `zh` 下经常输出**繁体**（"打開備忘錄"）。本脚本在入口统一转成简体（macOS 自带 Foundation 转换，约 0.1 秒，失败时原样放行）：否则按简体写的路由规则会全部失效、Laya 还会把繁体误判成危险操作、工具也会拿繁体应用名去启动。更彻底的做法是给 whisper-cli 加 `--prompt '以下是普通话的句子，请用简体中文转写。'`（需要重新构建 App；实测转写立即变简体）。

## 依赖

- macOS 14 或更高版本
- [Ollama](https://ollama.com/) 与 `qwen3.5:4b`
- `whisper-cpp` 及 `ggml-small.bin`
- 系统设置中已下载的高质量普通话 `Linfei` 声音
- 可选：已登录的 Codex CLI，用于处理需要云端能力的问题
- 可选：Laya 本地预筛，需要独立 MLX venv 与 `aac6fef/laya-multilingual-mlx` 权重

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

首次使用时，macOS 会请求麦克风权限。云端升级通过 `Resources/cloud_model.py` 统一入口依次尝试 ChatGPT.app 内置 Codex（Terra）和 `PATH` 中的 Codex CLI 两条通道，全部失败时用中文语音提示原因；`Resources/cloud-provider.example.json` 只决定入口路径。

## 云端说明

- 2026-09-13 起 `cloud-provider.json` 指向 `cloud_model.py`；两条通道都保持 `read-only` 沙箱、`--ephemeral` 临时会话，不改本机状态。
- 任一通道命中用量上限（`usage limit`/`quota`）或超时，自动尝试下一条；全部失败时播报"云端账号已达用量上限"或"云端模型暂时不可用"。
- 云端回退总预算最长约 210 秒，控制在 App 侧 240 秒超时以内。

## Laya 本地预筛（可选）

没有工具提示、也没被上面的正则拦下的请求，可以先交给本机 Laya（mmBERT-base 多语言，MLX）判断是否需要云端。M1 实测整次调用约 1 秒（含独立进程与模型加载），远快于让本地模型答错或绕一圈再升级。它只回答是非问题并给出"建议升级云端"，不做执行决策：开关关闭、venv 缺失、超时、输出异常都按"无意见"跳过，此时行为与未安装时完全一致。

```sh
# 1. 独立 venv（需要 Python 3.11+，可用 uv 或 python3）
uv venv "$HOME/Library/Application Support/LocalSiriLLM/laya-venv" --python 3.12
"$HOME/Library/Application Support/LocalSiriLLM/laya-venv/bin/python" -m pip install laya-mlx

# 2. 首次拉取权重（约 650 MB；之后走本机 HF 缓存离线运行）
echo '今天天气怎么样' | "$HOME/Library/Application Support/LocalSiriLLM/laya-venv/bin/python" \
  "$HOME/Library/Application Support/LocalSiriLLM/laya_router.py"

# 3. 打开开关
echo '{"enabled": true}' > "$HOME/Library/Application Support/LocalSiriLLM/laya-routing.json"
```

停用：把 `laya-routing.json` 的 `enabled` 改为 `false`，或删除该文件。

实测边界（20 条中文指令，阈值 0.55）：危险类 5/5 拦下，实时类 3/5 命中，自动判定的部分没有危险方向误判；中文多选分类准确率只有 35%，因此这里只使用是非判断（noul），不用它决定"直接执行"。带工具提示的请求（含"打开""音量""硬盘"等词）仍走原路径，不经过 Laya。

## 本地 AI 中枢管理界面

```sh
./configure.command
```

管理窗口是原生 macOS `NSWindow`（AppKit + SwiftUI 页面），不依赖网页或 WebView；窗口支持拖拽缩放，窄窗口会把双列内容自动堆叠，避免内容压到左侧导航。

管理界面按 Lunacy 稿分成「总览、语音助手、本地路由、Agent 管理、Jev 档位、设置与状态」六页，读写同一份 `~/Library/Application Support/LocalSiriLLM/router.json`。现有路由器使用的“每个 provider 自带地址和模型”的平面配置也会直接展示，不会为了显示界面自动迁移或改写配置；编辑器保存时只改选中的 provider，新增模型则复制为新的独立线路。

## 验证

```sh
/usr/bin/python3 \
  "$HOME/Library/Application Support/LocalSiriLLM/local_assistant.py" \
  --doctor
```

`--doctor` 额外检查 `tool_routing_ok`：提醒/搜索类请求会走工具路径，改写类请求走快路径。只读询问（时间、音量、电池、磁盘）必须使用只读工具，不允许用 `set_volume` 之类的写工具冒充查询。

语音状态通过 `~/Library/Application Support/LocalSiriLLM/touchbar-state.tsv` 提供给 Bar Control；处理过程中再次点击语音模块会取消当前任务并清理临时录音。
