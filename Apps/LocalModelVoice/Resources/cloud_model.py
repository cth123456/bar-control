#!/usr/bin/env python3
"""云端升级统一入口：依次尝试多个 Codex 通道，输出第一个成功回答。

被「本地模型.app」通过 cloud-provider.json 的 executable 调用：提示词从 stdin 读入，
回答写到 stdout。全部通道失败时向 stderr 输出简短中文原因并以非零退出，
App 会把它作为语音错误播报。所有通道都保持只读沙箱、临时会话，不修改本机状态。

安全说明：可执行文件与参数全部为写死的字面量，运行时不拼接、不插值用户文本；
用户提示词仅通过子进程标准输入传递。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid

QUOTA_MARKERS = ("usage limit", "rate limit", "quota")
GENERIC_REASON = "云端模型暂时不可用，请稍后再试"
QUOTA_REASON = "云端账号已达用量上限，请稍后再试"

# DSH 模型桥：DSH 客户端运行时暴露一个本地文件信箱，插件轮询它并用 DSH 自己配置的
# 模型通道（deepseek-official 等）作答。实测一次约 2.4 秒；而 codex exec 因为要加载
# 两万 token 的系统提示，回答两个字也要 60 秒。所以这里是第一优先通道。
BRIDGE_DIR = os.path.expanduser("~/Library/Application Support/LocalSiriLLM/dsh-bridge")
BRIDGE_REQUEST = os.path.join(BRIDGE_DIR, "request.json")
BRIDGE_RESPONSE = os.path.join(BRIDGE_DIR, "response.json")
BRIDGE_TIMEOUT = 90.0
BRIDGE_POLL = 0.15


def run_dsh_bridge(task_text: str) -> tuple[bool, str, str]:
    """把请求投进 DSH 的信箱并等待回答；DSH 没运行时快速失败，交给后面的通道。"""
    try:
        os.makedirs(BRIDGE_DIR, exist_ok=True)
        request_id = uuid.uuid4().hex
        # 先清掉上一次的回答，避免误读成这次的
        try:
            os.remove(BRIDGE_RESPONSE)
        except FileNotFoundError:
            pass
        pending = BRIDGE_REQUEST + ".tmp"
        with open(pending, "w", encoding="utf-8") as handle:
            json.dump({"id": request_id, "prompt": task_text}, handle, ensure_ascii=False)
        os.replace(pending, BRIDGE_REQUEST)

        deadline = time.time() + BRIDGE_TIMEOUT
        while time.time() < deadline:
            try:
                with open(BRIDGE_RESPONSE, encoding="utf-8") as handle:
                    payload = json.load(handle)
            except (FileNotFoundError, json.JSONDecodeError):
                payload = None
            if isinstance(payload, dict) and payload.get("id") == request_id:
                answer = str(payload.get("answer") or "").strip()
                if answer:
                    return True, answer, ""
                return False, "", f"DSH 桥返回错误：{payload.get('error') or '空回答'}"
            time.sleep(BRIDGE_POLL)
        return False, "", "DSH 桥超时（DSH 客户端可能没在运行）"
    except Exception as exc:
        return False, "", f"DSH 桥不可用：{exc}"


def _collect(child: subprocess.Popen, name: str, task_text: str, timeout: float) -> tuple[bool, str, str]:
    """等待子进程结束并判定结果。task_text 已在启动时通过 stdin 传入。"""
    try:
        out, err = child.communicate(input=task_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()
        return False, "", f"{name} 超时"

    out = (out or "").strip()
    err = (err or "").strip()
    combined = f"{out}\n{err}".lower()
    if child.returncode != 0 or not out or any(m in combined for m in QUOTA_MARKERS):
        return False, "", err or f"{name} 退出码 {child.returncode}"
    return True, out, ""


def run_terra(task_text: str) -> tuple[bool, str, str]:
    try:
        child = subprocess.Popen(
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "--search",
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                "--color",
                "never",
                "-m",
                "gpt-5.6-terra",
                "-c",
                'model_reasoning_effort="medium"',
                "-C",
                "/private/tmp",
                "-",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        return False, "", f"Codex Terra 无法启动：{exc}"
    return _collect(child, "Codex Terra", task_text, 100.0)


def run_homebrew_codex(task_text: str) -> tuple[bool, str, str]:
    try:
        child = subprocess.Popen(
            [
                "/opt/homebrew/bin/codex",
                "--search",
                "exec",
                "--ephemeral",
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                "--color",
                "never",
                "-c",
                'model_reasoning_effort="medium"',
                "-C",
                "/private/tmp",
                "-",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        return False, "", f"Codex CLI 无法启动：{exc}"
    return _collect(child, "Codex CLI", task_text, 110.0)


def main() -> int:
    task_text = sys.stdin.read().strip()
    if not task_text:
        print("云端输入为空。", file=sys.stderr)
        return 2
    if len(task_text) > 6000:
        task_text = task_text[:6000]

    details: list[str] = []
    for runner in (run_dsh_bridge, run_terra, run_homebrew_codex):
        ok, stdout, detail = runner(task_text)
        if ok:
            print(stdout)
            return 0
        details.append(detail)

    combined = " ".join(details).lower()
    reason = QUOTA_REASON if any(m in combined for m in QUOTA_MARKERS) else GENERIC_REASON
    print(reason, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
