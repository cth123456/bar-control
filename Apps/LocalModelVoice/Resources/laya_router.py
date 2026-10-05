#!/usr/bin/env python3
"""Laya 本地快速分流预筛：只给建议，不执行任何操作。

请求文本从 stdin 读入，单行 JSON 写到 stdout：

    {"verdict": "cloud"|"none", "reason": "...", "signals": {...}, "ms": 123.4}

判定策略与旧版完全一致：用多语言 Laya checkpoint（mmBERT-base）回答四个是非
问题，按安全优先顺序判定（危险 > 实时），只有明确超过 0.55 阈值时才建议升级
云端；其余一律返回 none，交给 local_assistant.py 现有的 qwen 分流处理。

与旧版的唯一区别是执行路径：

  1) 优先请求常驻守护进程 laya_server.py（模型只加载一次，暖推理约 0.1 秒）；
  2) 守护进程不可用时自动拉起它并等待就绪；
  3) 仍不可用则回退到进程内加载模型，行为与旧版逐字一致，只是每次多花约 1 秒。

任何异常都以 {"verdict": "none", ...} 返回，调用方按“无意见”处理，因此本文件
的任何故障都不会阻断语音链路。

安全约定：只做分类；不调用工具、不读写用户文件、不联网（模型走本机 HF 缓存）。
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time

BASE_DIR = os.path.expanduser("~/Library/Application Support/LocalSiriLLM")
SOCKET_PATH = os.path.join(BASE_DIR, "laya.sock")
SERVER = os.path.join(BASE_DIR, "laya_server.py")
PYTHON = os.path.join(BASE_DIR, "laya-venv", "bin", "python")
FLAG = os.path.join(BASE_DIR, "laya-routing.json")
SERVER_LOG = os.path.join(BASE_DIR, "laya-server.log")

# 超时预算刻意压在 local_assistant.py 的 LAYA_TIMEOUT(12s) 之内：
# 最坏情况 0.8 + 5.0 + 4.0 = 9.8s，避免被父进程杀掉而丢掉判定的机会。
CONNECT_TIMEOUT = 0.8
RESPONSE_TIMEOUT = 4.0
AUTOSTART_WAIT = 5.0

# 已下载的模型走本机 HF 缓存，避免每次调用都尝试联网；缓存缺失时保留联网下载能力。
_HF_CACHE = os.path.expanduser(
    "~/.cache/huggingface/hub/models--aac6fef--laya-multilingual-mlx"
)
if os.path.isdir(_HF_CACHE):
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

MODEL = "aac6fef/laya-multilingual-mlx"
THRESHOLD = 0.55
MAX_STATE_CHARS = 1500

QUESTIONS = {
    "dangerous": {
        "type": "noul",
        "instructions": (
            "Does `request` ask to delete, overwrite or erase data, run system commands, "
            "reset or wipe the computer, or otherwise cause irreversible or destructive changes?"
        ),
    },
    "realtime": {
        "type": "noul",
        "instructions": (
            "Does `request` need real-time information from the internet, such as weather, news, "
            "current prices, schedules, stock quotes, or a web search?"
        ),
    },
    "local_action": {
        "type": "noul",
        "instructions": (
            "Does `request` ask to perform a simple, safe, local computer action on this Mac, "
            "such as opening an app, changing the volume, reading the time or battery level, "
            "or using the clipboard?"
        ),
    },
    "general": {
        "type": "noul",
        "instructions": (
            "Is `request` a general knowledge question or a writing task that can be answered "
            "locally without tools, real-time data, or private files?"
        ),
    },
}


def decide(signals: dict[str, float]) -> tuple[str, str]:
    if signals.get("dangerous", 0.0) >= THRESHOLD:
        return "cloud", "该请求可能涉及删除、覆盖或不可逆改动，交给云端谨慎处理"
    if signals.get("realtime", 0.0) >= THRESHOLD:
        return "cloud", "该请求需要实时信息或联网核实"
    return "none", ""


def emit(payload: dict) -> int:
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    return 0


def autostart_enabled() -> bool:
    """默认开启守护进程自启；laya-routing.json 里 daemon.autostart=false 可关闭。"""
    try:
        with open(FLAG, encoding="utf-8") as handle:
            config = json.load(handle)
        section = config.get("daemon") or {}
        return bool(section.get("autostart", True))
    except Exception:
        return True


def ask_daemon(text: str) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.settimeout(RESPONSE_TIMEOUT)
        sock.sendall((json.dumps({"text": text}, ensure_ascii=False) + "\n").encode("utf-8"))
        buffer = b""
        while b"\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
    finally:
        try:
            sock.close()
        except OSError:
            pass
    line = buffer.decode("utf-8", "replace").split("\n")[0].strip()
    if not line:
        raise RuntimeError("守护进程没有返回内容")
    return json.loads(line)


def start_daemon() -> None:
    with open(SERVER_LOG, "ab") as log_handle:
        subprocess.Popen(
            [PYTHON, SERVER],
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
            close_fds=True,
        )


def wait_for_daemon(seconds: float) -> bool:
    deadline = time.perf_counter() + seconds
    while time.perf_counter() < deadline:
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.5)
            probe.connect(SOCKET_PATH)
            probe.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def via_daemon(text: str) -> dict | None:
    """走守护进程；不可用时（按需）拉起后重试一次。"""
    try:
        return ask_daemon(text)
    except Exception:
        pass
    if not autostart_enabled():
        return None
    if not (os.access(PYTHON, os.X_OK) and os.path.isfile(SERVER)):
        return None
    try:
        start_daemon()
    except Exception:
        return None
    if not wait_for_daemon(AUTOSTART_WAIT):
        return None
    try:
        return ask_daemon(text)
    except Exception:
        return None


def in_process(text: str, started: float) -> dict:
    """回退路径：与旧版逐字一致，只是每次都要重新加载模型。"""
    def elapsed() -> float:
        return round((time.perf_counter() - started) * 1000, 1)

    try:
        import laya_mlx as laya

        agent = laya.load(MODEL)
        answers = agent.predict(text, QUESTIONS)["answers"]
        signals = {key: round(float(value["noul"]), 3) for key, value in answers.items()}
        verdict, reason = decide(signals)
        if verdict == "cloud":
            return {"verdict": "cloud", "reason": reason, "signals": signals, "ms": elapsed()}
        return {"verdict": "none", "signals": signals, "ms": elapsed()}
    except Exception as exc:
        return {"verdict": "none", "error": str(exc)[:200], "ms": elapsed()}


def main() -> int:
    started = time.perf_counter()
    text = sys.stdin.read().strip()[:MAX_STATE_CHARS]
    if not text:
        return emit({"verdict": "none", "reason": "empty"})

    payload = via_daemon(text)
    if payload is not None:
        payload["source"] = "daemon"
        payload["ms"] = round((time.perf_counter() - started) * 1000, 1)
        return emit(payload)

    payload = in_process(text, started)
    payload["source"] = "in-process"
    return emit(payload)


if __name__ == "__main__":
    sys.exit(main())
