#!/bin/zsh
# AI助手 4230 网关的 launchd 子服务。
# 网关属于共享基础设施，不随 AI助手窗口进程退出。
set -u

DIR="$HOME/Library/Application Support/LocalSiriLLM"
PYTHON=/usr/bin/python3
PORT=4230
LOG="$DIR/gateway_4230.runtime.log"

export LOCAL_SIRI_ROUTER_CONFIG="$DIR/router.json"
export LOCAL_SIRI_ROUTER_STATS="$DIR/router-stats.json"
export LOCAL_SIRI_ROUTER_HEALTH="$DIR/router-health.json"

port_busy() {
  /usr/bin/nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
}

if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f%z "$LOG")" -gt 5242880 ]; then
  /bin/mv -f "$LOG" "$LOG.1"
fi

while true; do
  if port_busy; then
    /bin/sleep 15
    continue
  fi
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] supervisor 启动网关 → 127.0.0.1:$PORT (agent=router.json)" >>"$LOG"
  # 不在守护脚本里写死 Agent；unified_router.py 从 router.json.gateway.agent_id 读取。
  "$PYTHON" "$DIR/unified_router.py" --serve --port "$PORT" >>"$LOG" 2>&1
  code=$?
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 网关进程退出（code=$code），15 秒后检查重试" >>"$LOG"
  /bin/sleep 15
done
