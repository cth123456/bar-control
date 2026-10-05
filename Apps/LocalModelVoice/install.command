#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
source_app=$($project_dir/build.command)
target_app="/Applications/AI助手.app"
legacy_app="/Applications/本地模型.app"
backup_dir="$HOME/Library/Application Support/LocalSiriLLM/backups"
timestamp=$(/bin/date +%Y%m%d-%H%M%S)

# 安装必须停掉正在运行的 App 才能替换二进制。停之前先记住它原来是不是开着的：
# 开着的话装完要拉回来，否则每装一次都会「莫名其妙」留一个关闭的 App，
# 用户得自己重新打开 —— 那是安装器的副作用，不是 App 崩了。
was_running=0
if /usr/bin/pgrep -x LocalModelVoice >/dev/null; then
    was_running=1
fi

/usr/bin/pkill -TERM -x LocalModelVoice 2>/dev/null || true
for _ in {1..20}; do
    /usr/bin/pgrep -x LocalModelVoice >/dev/null || break
    /bin/sleep 0.1
done
if /usr/bin/pgrep -x LocalModelVoice >/dev/null; then
    /usr/bin/pkill -KILL -x LocalModelVoice 2>/dev/null || true
fi

/bin/mkdir -p "$backup_dir"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for old_app in "$target_app" "$legacy_app"; do
    if [[ -d "$old_app" ]]; then
        "$lsregister" -u "$old_app" 2>/dev/null || true
        old_name=${old_app:t:r}
        /bin/mv "$old_app" "$backup_dir/${old_name}-before-ai-assistant-${timestamp}.app.backup"
    fi
done

# Remove the old, generated development copy after stopping its process so it cannot be launched by accident.
legacy_build="$project_dir/.build/本地模型.app"
if [[ -d "$legacy_build" ]]; then
    /usr/bin/python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$legacy_build"
fi
/usr/bin/ditto --rsrc --extattr "$source_app" "$target_app"
/usr/bin/touch "$target_app"
"$lsregister" -f "$target_app"
/usr/bin/codesign --verify --deep --strict "$target_app"
/bin/mkdir -p "$HOME/Library/Application Support/LocalSiriLLM"
# The installed app invokes this router from the support directory; keep it in
# sync with the build while preserving router.json and all user credentials.
# 支持目录里的脚本可能比仓库里的新（直接在生产副本上做的修复还没回流）：覆盖前先留一份
# 时间戳备份，避免一次重装把改动静默冲掉。
support_router="$HOME/Library/Application Support/LocalSiriLLM/unified_router.py"
if [[ -f "$support_router" ]] && ! /usr/bin/cmp -s "$project_dir/Resources/unified_router.py" "$support_router"; then
    /bin/cp "$support_router" "$support_router.bak-$(/bin/date +%Y%m%d-%H%M%S)"
fi
/usr/bin/ditto "$project_dir/Resources/unified_router.py" "$support_router"
/bin/chmod +x "$support_router"

support_catalog_sync="$HOME/Library/Application Support/LocalSiriLLM/sync-codex-agent-catalog.py"
/usr/bin/ditto "$project_dir/Tools/sync-codex-agent-catalog.py" "$support_catalog_sync"
/bin/chmod 700 "$support_catalog_sync"

# 4230 是 Codex 等客户端共用的基础服务：由 launchd 托管，不能再挂在
# AI助手窗口的子进程上。安装器负责同步 supervisor、生成当前用户的
# LaunchAgent 路径，并重新加载它；router.json 和密钥保持不动。
support_dir="$HOME/Library/Application Support/LocalSiriLLM"
supervisor="$support_dir/gateway_4230_supervisor.sh"
plist="$HOME/Library/LaunchAgents/com.local.localmodelvoice.gateway-4230.plist"
template="$project_dir/Resources/com.local.localmodelvoice.gateway-4230.plist.in"
if [[ -f "$supervisor" ]] && ! /usr/bin/cmp -s "$project_dir/Resources/gateway_4230_supervisor.sh" "$supervisor"; then
    /bin/cp "$supervisor" "$supervisor.bak-$(/bin/date +%Y%m%d-%H%M%S)"
fi
/usr/bin/ditto "$project_dir/Resources/gateway_4230_supervisor.sh" "$supervisor"
/bin/chmod 700 "$supervisor"
/bin/mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
if [[ -f "$plist" ]] && ! /usr/bin/cmp -s "$template" "$plist"; then
    /bin/cp "$plist" "$plist.bak-$(/bin/date +%Y%m%d-%H%M%S)"
fi
/usr/bin/python3 - "$template" "$plist" "$supervisor" "$support_dir" "$HOME/Library/Logs" <<'PY'
import pathlib
import sys

template, target, supervisor, support_dir, log_dir = map(pathlib.Path, sys.argv[1:])
text = template.read_text(encoding="utf-8")
text = text.replace("__SUPERVISOR_PATH__", str(supervisor))
text = text.replace("__SUPPORT_DIR__", str(support_dir))
text = text.replace("__LOG_DIR__", str(log_dir))
target.write_text(text, encoding="utf-8")
PY
/usr/bin/plutil -lint "$plist" >/dev/null
uid=$(/usr/bin/id -u)
/bin/launchctl bootout "gui/$uid/com.local.localmodelvoice.gateway-4230" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$uid" "$plist"
/bin/launchctl kickstart -k "gui/$uid/com.local.localmodelvoice.gateway-4230"

# Codex 已经走 4230 default Agent，模型选择器不能继续读取 4202 的原生-only
# merged catalog；发布一份由 router.json default Agent 生成的本地目录。
/usr/bin/python3 "$project_dir/Tools/sync-codex-agent-catalog.py"

# 保留一个不影响默认 4230 路由的直连 profile。只生成模型目录和端点配置，
# API Key 由用户自己的 DEEPSEEK_API_KEY 环境变量提供，绝不从 router.json 复制。
direct_profile="$HOME/.codex/codex-direct.config.toml"
direct_catalog="$HOME/.codex/codex-direct-models.json"
direct_template="$project_dir/Resources/codex-direct.config.toml.in"
/usr/bin/python3 - "$direct_template" "$direct_profile" "$direct_catalog" "$HOME/.codex/ai-assistant-models.json" <<'PY'
import json
import pathlib
import sys

template, profile, catalog, source = map(pathlib.Path, sys.argv[1:])
profile.parent.mkdir(parents=True, exist_ok=True)
if not profile.exists():
    profile.write_text(
        template.read_text(encoding="utf-8").replace("__DIRECT_CATALOG__", str(catalog)),
        encoding="utf-8",
    )
try:
    payload = json.loads(source.read_text(encoding="utf-8"))
    rows = [
        row for row in payload.get("models", [])
        if isinstance(row, dict)
        and row.get("slug") in {"deepseek-flash", "deepseek-v4-pro"}
    ]
    catalog.write_text(json.dumps({"models": rows}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
except (OSError, ValueError, TypeError):
    pass
PY

echo "直连 profile 已准备：$direct_profile（不改变当前默认 4230 路由）"

echo "已安装：$target_app"
echo "旧版已备份至：$backup_dir"
echo "4230 已交给 launchd 托管：$plist"

# 还原安装前的运行状态：装之前开着就拉回来，装之前没开就不擅自启动。
if [[ $was_running -eq 1 ]]; then
    /usr/bin/open "$target_app"
    /bin/sleep 1
    if /usr/bin/pgrep -x LocalModelVoice >/dev/null; then
        echo "AI助手 已重新拉起（安装前它本来就在运行）"
    else
        echo "提示：AI助手 未能自动拉起，请手动打开 $target_app"
    fi
fi
