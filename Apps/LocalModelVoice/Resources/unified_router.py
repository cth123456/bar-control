#!/usr/bin/env python3
"""本地模型助手的统一供应商路由器。

输入：stdin 中的一段用户提示词
输出：stdout 中第一个成功供应商的回答

配置文件位于：
    ~/Library/Application Support/LocalSiriLLM/router.json

配置模型：
{
  "version": 1,
  "providers": [
    {
      "id": "dsh",
      "name": "DSH",
      "kind": "dsh_bridge",
      "enabled": true
    },
    {
      "id": "teamorouter",
      "name": "TeamoRouter · GPT-6 Astra",
      "kind": "openai_compatible",
      "base_url": "https://api.teamorouter.com/v1",
      "api_key": "sk-...",
      "wire_api": "chat_completions",
      "model": "GPT-6 Astra"
    }
  ],
  "agents": [
    {"id": "default", "name": "默认助手", "provider_ids": ["dsh", "teamorouter"]}
  ],
  "assistant_agent": "default"
}

一个"供应商"= 一条线路 + 一个模型；Agent 只保存供应商 id 的顺序，
所以改一个供应商的 API Key / 地址 / 模型，所有引用它的 Agent 一起生效。
assistant_agent 只决定"语音助手云端通道默认用哪个 Agent"，
其它 Agent（编码、写作…）由调用方自己传 --agent。

API Key 只保存在用户目录的 router.json（安装时 chmod 600），不写入仓库。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlparse


BASE_DIR = Path(os.path.expanduser("~/Library/Application Support/LocalSiriLLM"))
CONFIG_PATH = Path(
    os.environ.get("LOCAL_SIRI_ROUTER_CONFIG", str(BASE_DIR / "router.json"))
)
# 命中率只记录真实发生过的调用结果，不猜、不补零。
STATS_PATH = Path(
    os.environ.get("LOCAL_SIRI_ROUTER_STATS", str(BASE_DIR / "router-stats.json"))
)
HEALTH_PATH = Path(
    os.environ.get("LOCAL_SIRI_ROUTER_HEALTH", str(BASE_DIR / "router-health.json"))
)


def record_stat(provider: dict[str, Any], ok: bool, error: str = "") -> None:
    identifier = str(provider.get("id") or "")
    if not identifier:
        return
    try:
        data = json.loads(STATS_PATH.read_text(encoding="utf-8")) if STATS_PATH.exists() else {}
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}
    entry = data.get(identifier)
    if not isinstance(entry, dict):
        entry = {}
    entry["attempts"] = int(entry.get("attempts") or 0) + 1
    if ok:
        entry["successes"] = int(entry.get("successes") or 0) + 1
        entry["last_error"] = ""
    else:
        entry["failures"] = int(entry.get("failures") or 0) + 1
        entry["last_error"] = str(error)[:200]
    entry["last_attempt_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    data[identifier] = entry
    try:
        STATS_PATH.parent.mkdir(parents=True, exist_ok=True)
        temporary = STATS_PATH.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(temporary, STATS_PATH)
        os.chmod(STATS_PATH, 0o600)
    except Exception:
        pass  # 统计写不进去也绝不能影响回答

DEFAULT_TIMEOUT = 90.0
# 整轮故障转移的总时间上限：App 给自己的超时是 240s，这里留出余量，
# 免得"十条线路各等 90s"把整轮拖过 App 的截止时间、连一句人话都说不出来。
DEFAULT_BUDGET = 200.0
DSH_SETTINGS_PATH = Path(os.path.expanduser("~/.dsh/settings.yaml"))
DSH_CREDENTIALS_PATH = Path(os.path.expanduser("~/.dsh/.credentials.yaml"))
# 三方中转站的来源：Codex 自己的 config.toml 里手写的 [model_providers.*]。
CODEX_CONFIG_PATH = Path(os.path.expanduser("~/.codex/config.toml"))
# 总路由（网关）默认端口：4202 被 codex-router 占用，这里错开一格。
GATEWAY_DEFAULT_PORT = 4230
GATEWAY_DEFAULT_HOST = "127.0.0.1"
DSH_WIRE_API = {
    "openai-completions": ("chat_completions", "openai_compatible"),
    "openai-responses": ("responses", "openai_compatible"),
}
QUOTA_MARKERS = (
    "usage limit",
    "rate limit",
    "quota",
    "insufficient_quota",
    "credits",
    "429",
    "too many requests",
)
# 只有这些词才表示“今天的额度窗口已经用尽”。普通 429 / rate limit
# 可能几秒后恢复，不能把它们当成全天熔断。
QUOTA_EXHAUSTED_MARKERS = (
    "quota_exceeded",
    "quota exhausted",
    "usage limit reached",
    "usage limit exceeded",
    "insufficient_quota",
    "free_request_quota_exhausted",
    "daily quota",
    "daily limit",
    "credits exhausted",
    "out of credits",
)


def is_quota_exhausted_error(error: Any) -> bool:
    text = str(error or "").lower()
    return any(marker in text for marker in QUOTA_EXHAUSTED_MARKERS)


def provider_quota_exhausted_today(provider: dict[str, Any]) -> bool:
    """只在本地日期内跳过明确的额度耗尽线路；跨日自动恢复探测。"""
    identifier = str(provider.get("id") or "")
    if not identifier:
        return False
    try:
        data = json.loads(STATS_PATH.read_text(encoding="utf-8")) if STATS_PATH.exists() else {}
        entry = data.get(identifier) if isinstance(data, dict) else None
    except Exception:
        entry = None
    if not isinstance(entry, dict) or not is_quota_exhausted_error(entry.get("last_error")):
        return False
    stamp = str(entry.get("last_attempt_at") or "").strip()
    try:
        attempted = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if attempted.tzinfo is None:
            attempted = attempted.replace(tzinfo=timezone.utc)
        return attempted.astimezone().date() == datetime.now().astimezone().date()
    except (TypeError, ValueError):
        return False


def default_config() -> dict[str, Any]:
    return {
        "version": 1,
        # 客户端分配是控制层数据；不要把 Codex 的 model_provider 当成分配表。
        "client_assignments": {},
        "providers": [
            {
                "id": "dsh",
                "name": "DSH",
                "kind": "dsh_bridge",
                "enabled": True,
                "timeout_seconds": 90,
            },
            {
                "id": "codex-terra",
                "name": "Codex Terra",
                "kind": "command",
                "enabled": True,
                "executable": "/Applications/ChatGPT.app/Contents/Resources/codex",
                "arguments": [
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
                "timeout_seconds": 100,
            },
            {
                "id": "codex-cli",
                "name": "Codex CLI",
                "kind": "command",
                "enabled": True,
                "executable": "/opt/homebrew/bin/codex",
                "arguments": [
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
                "timeout_seconds": 110,
            },
        ],
        "agents": [
            {
                "id": "default",
                "name": "默认助手",
                "provider_ids": ["dsh", "codex-terra", "codex-cli"],
                "system_prompt": "",
            }
        ],
    }


def ensure_config() -> dict[str, Any]:
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        payload = default_config()
        write_config(payload)
        return payload
    try:
        with CONFIG_PATH.open(encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise ValueError("router.json 顶层必须是对象")
        payload.setdefault("providers", [])
        payload.setdefault("agents", [])
        payload.setdefault("client_assignments", {})
        if not isinstance(payload["client_assignments"], dict):
            payload["client_assignments"] = {}
        return payload
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"无法读取路由配置：{exc}") from exc


def write_config(payload: dict[str, Any]) -> None:
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    temporary = CONFIG_PATH.with_suffix(".json.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


def find_agent(config: dict[str, Any], agent_id: str) -> dict[str, Any]:
    agents = config.get("agents") or []
    for agent in agents:
        if isinstance(agent, dict) and agent.get("id") == agent_id:
            return agent
    # 脚本 / 快捷指令里人们更习惯写 Agent 的显示名（比如「翻译助手」），
    # 找不到 id 时再按名字匹配一次，避免静默回落到默认助手。
    wanted = agent_id.strip().lower()
    for agent in agents:
        if isinstance(agent, dict) and str(agent.get("name") or "").strip().lower() == wanted:
            return agent
    if agent_id != "default":
        return find_agent(config, "default")
    return {"id": "default", "provider_ids": []}


def agent_ids(config: dict[str, Any]) -> list[str]:
    return [
        str(agent.get("id"))
        for agent in config.get("agents", [])
        if isinstance(agent, dict) and agent.get("id")
    ]


def resolve_agent_id(config: dict[str, Any], requested: str | None) -> str:
    """这一轮走哪个 Agent：显式 --agent > router.json 的 assistant_agent > omni > default。

    语音助手（App 的云端通道）没有命令行参数可用，靠 assistant_agent 决定；
    GUI 里"把所选 Agent 设为助手默认"写的就是这个键。
    """
    known = agent_ids(config)
    if requested:
        if requested not in known:
            print(f"提示：没有名为 {requested} 的 Agent，按 default 处理。", file=sys.stderr)
        return requested
    chosen = str(config.get("assistant_agent") or "").strip()
    if chosen:
        if chosen in known:
            return chosen
        print(
            f"提示：assistant_agent={chosen} 不在 agents 里，已回落。",
            file=sys.stderr,
        )
    if "omni" in known:
        return "omni"
    return "default"


def providers_for_agent(
    config: dict[str, Any], agent_id: str
) -> list[dict[str, Any]]:
    connections = {
        connection.get("id"): connection
        for connection in config.get("connections", [])
        if isinstance(connection, dict) and connection.get("id")
    }
    provider_map = {
        provider.get("id"): provider
        for provider in config.get("providers", [])
        if isinstance(provider, dict) and provider.get("id")
    }
    result = []
    for provider_id in find_agent(config, agent_id).get("provider_ids", []):
        provider = provider_map.get(provider_id)
        if provider and provider.get("enabled", True):
            connection = connections.get(provider.get("connection_id"), {})
            # Connection settings are the single source of URL/key/protocol;
            # model rows contain only model-specific fields and routing order.
            result.append({**connection, **provider})
    return result


JEV_PROVIDER_ID = "codex-router-jev-auto"
JEV_INTERNAL_MODEL = "jev/auto"


def external_model_name(provider: dict[str, Any]) -> str:
    """模型池/客户端对外名称；与 4202 内部名称统一为 jev/auto。"""
    provider_id = str(provider.get("id") or "")
    model = str(provider.get("model") or "")
    return JEV_INTERNAL_MODEL if provider_id == JEV_PROVIDER_ID or model == JEV_INTERNAL_MODEL else model


def external_model_catalog(providers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """给客户端的模型目录：4202 内部具体线路不逐条外露，只保留 jev/auto。"""
    result: list[dict[str, Any]] = []
    for provider in providers:
        source = str(provider.get("source") or "").lower()
        if str(provider.get("kind") or "").lower() == "dsh_bridge":
            continue
        if source == "dsh:codex-router":
            if str(provider.get("id") or "") != JEV_PROVIDER_ID:
                continue
            result.append(provider)
            continue
        result.append(provider)
    return result


NATIVE_CODEX_CATALOG_PATH = Path(os.path.expanduser("~/.codex/codex-router/merged-models.json"))
CODEX_PICKER_CATALOG_PATH = Path(os.path.expanduser("~/.codex/ai-assistant-models.json"))
_native_codex_slugs = None


def native_codex_slugs():
    """Codex 原生模型 slug 集合（来自 4202 的原生目录 merged-models.json）。"""
    global _native_codex_slugs
    if _native_codex_slugs is not None:
        return _native_codex_slugs
    slugs = set()
    try:
        data = json.loads(NATIVE_CODEX_CATALOG_PATH.read_text(encoding="utf-8"))
        for row in data.get("models") or []:
            if isinstance(row, dict) and row.get("slug"):
                slugs.add(str(row["slug"]).strip())
    except Exception:
        slugs = set()
    _native_codex_slugs = slugs
    return slugs


def is_native_codex_model(model):
    """原生 Codex 模型：既认 4202 目录里的 slug，也认 gpt-* 的命名兜底。"""
    value = str(model or "").strip().lower()
    if not value:
        return False
    if value in native_codex_slugs():
        return True
    return value.startswith("gpt-") or value in {"codex-auto-review"}


def native_codex_relay_provider(config, model):
    """为原生 Codex 模型造一条指向 4202 codex-router 的转发线路（只内存，不写盘）。"""
    for provider in config.get("providers") or []:
        if not isinstance(provider, dict):
            continue
        if str(provider.get("source") or "").lower() != "dsh:codex-router":
            continue
        if not str(provider.get("base_url") or "").strip():
            continue
        synth = dict(provider)
        synth["id"] = "native-codex-" + model
        synth["model"] = model
        synth["name"] = "Codex 原生 · " + model
        synth["source"] = "native-codex"
        synth["stream"] = True
        return synth
    return None


def codex_picker_models(config: dict[str, Any]) -> list[dict[str, Any]]:
    """The model list shared by Codex's picker and the 4230 /models route."""
    try:
        payload = json.loads(CODEX_PICKER_CATALOG_PATH.read_text(encoding="utf-8"))
        rows = payload.get("models") if isinstance(payload, dict) else None
        if isinstance(rows, list):
            return [row for row in rows
                    if isinstance(row, dict)
                    and str(row.get("slug") or "").strip()
                    and str(row.get("visibility") or "list") != "hide"]
    except (OSError, ValueError, TypeError):
        pass

    native = []
    try:
        payload = json.loads(NATIVE_CODEX_CATALOG_PATH.read_text(encoding="utf-8"))
        rows = payload.get("models") if isinstance(payload, dict) else None
        if isinstance(rows, list):
            native = [row for row in rows
                      if isinstance(row, dict)
                      and str(row.get("slug") or "").strip()
                      and str(row.get("visibility") or "list") != "hide"]
    except (OSError, ValueError, TypeError):
        pass
    selected = client_assignment_models(config, "codex")
    native_slugs = {str(row.get("slug")) for row in native}
    return native + [{"slug": model, "display_name": model}
                     for model in selected
                     and model not in native_slugs]


MODEL_FETCH_TIMEOUT = 12
MODEL_FETCH_SUFFIXES = (
    "/api/claudecode", "/api/anthropic", "/apps/anthropic", "/api/coding",
    "/claudecode", "/anthropic", "/step_plan", "/coding", "/claude",
)


def model_endpoint_candidates(base_url: str) -> list[str]:
    """OpenAI-compatible model catalog URL candidates, without credentials in URLs."""
    value = str(base_url or "").strip().rstrip("/")
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("URL 必须以 http:// 或 https:// 开头")
    if parsed.username or parsed.password:
        raise ValueError("请把认证信息填在 API Key 栏，不要放进 URL")
    if parsed.query or parsed.fragment:
        raise ValueError("模型接口 URL 不接受 query 或 fragment 参数")
    path = parsed.path.rstrip("/")
    origin = f"{parsed.scheme}://{parsed.netloc}"
    if path.endswith("/models"):
        return [value]
    if path.endswith("/chat/completions") or path.endswith("/responses") or path.endswith("/messages"):
        path = path.rsplit("/", 1)[0]
    root_path = path
    for suffix in MODEL_FETCH_SUFFIXES:
        if root_path.lower().endswith(suffix):
            root_path = root_path[:-len(suffix)].rstrip("/")
            break
    root = origin + root_path
    if path.lower().endswith("/api/plan/v3"):
        candidates = [root + "/models", root[:-len("/api/plan/v3")] + "/api/v3/models"]
    elif re.search(r"/v[0-9]+$", path):
        candidates = [root + "/models"]
        if not path.endswith("/v1"):
            candidates.append(root + "/v1/models")
    else:
        candidates = [root + "/v1/models", root + "/models"]
    return list(dict.fromkeys(candidates))


def fetch_models(base_url: str, api_key: str = "", wire_api: str = "chat_completions") -> dict[str, Any]:
    """Probe the provider using a no-generation GET /models request and return latency."""
    candidates = model_endpoint_candidates(base_url)
    key = resolve_secret(api_key).strip()
    headers = {"Accept": "application/json", "User-Agent": "AI-Assistant/2.3"}
    if key:
        if wire_api == "anthropic_messages":
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
        else:
            headers["Authorization"] = f"Bearer {key}"
    last_status = None
    last_message = ""
    saw_catalog_not_found = False
    # 只有「每个候选地址都明确答 404/405/501」才算这个接口没有目录接口。
    # 中途撞上超时、网络错误或别的状态码，说明它出的是别的问题：那时候再发一次生成请求也是白烧 token。
    saw_other_failure = False
    for endpoint in candidates:
        started = time.perf_counter()
        request = urllib.request.Request(endpoint, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=MODEL_FETCH_TIMEOUT) as response:
                raw = response.read(2_000_001)
                if len(raw) > 2_000_000:
                    raise RuntimeError("模型列表响应超过 2 MB 限制")
                payload = json.loads(raw.decode("utf-8", "replace"))
            rows = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(rows, list) and isinstance(payload, dict):
                rows = payload.get("models")
            if not isinstance(rows, list):
                raise RuntimeError("响应缺少 data[] 或 models[] 模型列表")
            models = []
            seen = set()
            for row in rows:
                if not isinstance(row, dict):
                    continue
                identifier = str(row.get("id") or row.get("slug") or "").strip()
                if not identifier or identifier in seen:
                    continue
                seen.add(identifier)
                models.append({
                    "id": identifier,
                    "owned_by": str(row.get("owned_by") or row.get("provider") or ""),
                    "name": str(row.get("name") or identifier),
                })
            if not models:
                raise RuntimeError("供应商返回了空模型列表")
            models.sort(key=lambda item: item["id"].lower())
            primary = candidates[0]
            fallback = endpoint != primary
            answer: dict[str, Any] = {
                "ok": True,
                "status": "catalog-only" if fallback else "connected",
                "latency_ms": round((time.perf_counter() - started) * 1000),
                "endpoint": endpoint,
                "address_matches": not fallback,
                "model_count": len(models),
                "models": models,
                "catalog_unavailable": False,
            }
            if fallback:
                # 配置地址自己没有目录接口，这份名单是回退地址给的。读到名单 ≠ 能出字。
                answer["warning"] = (
                    f"配置地址 {primary} 不提供目录；名单来自回退地址 {endpoint}，"
                    "尚未验证该地址能生成内容"
                )
            return answer
        except urllib.error.HTTPError as exc:
            last_status = exc.code
            # Never return a URL, request header, or API key in probe output.
            last_message = f"HTTP {exc.code}"
            if exc.code in {404, 405, 501}:
                saw_catalog_not_found = True
            if exc.code not in {404, 405, 501}:
                saw_other_failure = True
                break
        except urllib.error.URLError as exc:
            last_message = f"网络错误：{type(exc.reason).__name__}"
            saw_other_failure = True
            break
        except (TimeoutError, OSError) as exc:
            last_message = "连接超时" if isinstance(exc, TimeoutError) else "网络错误"
            saw_other_failure = True
            break
        except (ValueError, RuntimeError) as exc:
            last_message = str(exc)[:180]
            saw_other_failure = True
            break
    return {
        "ok": False,
        "status": "unreachable",
        "latency_ms": None,
        "error": ("该接口不提供 GET /models；请改用标准 /api/v3 地址，或手动加入模型名"
                  if saw_catalog_not_found else
                  last_message or (f"HTTP {last_status}" if last_status else "模型接口不可用")),
        "models": [],
        "catalog_unavailable": bool(saw_catalog_not_found and not saw_other_failure),
    }


def load_router_health(path: Path | None = None) -> dict[str, Any]:
    target = Path(path or HEALTH_PATH)
    try:
        payload = json.loads(target.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else {}
    except (OSError, ValueError):
        return {}


def is_loopback_url(value: Any) -> bool:
    """127.0.0.1 / localhost / ::1：探测绿灯只说明本机服务在应答，不代表外部上游可用。"""
    try:
        host = (urlparse(str(value or "").strip()).hostname or "").lower()
    except ValueError:
        return False
    return host in {"127.0.0.1", "localhost", "::1", "0.0.0.0"}


def probe_all_connections(config: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
    """探测每条线路的 /models；只有「接口自己说没有 /models」才再发一次极小生成请求兜底。"""
    connection_items = [
        item for item in config.get("connections", [])
        if isinstance(item, dict) and item.get("id") and item.get("base_url")
    ]
    jobs: dict[str, dict[str, Any]] = {}
    provider_job: dict[str, str] = {}
    legacy_providers: dict[str, dict[str, Any]] = {}
    for connection in connection_items:
        cid = str(connection["id"])
        jobs[f"connection:{cid}"] = {
            "base_url": str(connection.get("base_url") or ""),
            "api_key": connection.get("api_key") or "",
            "wire_api": str(connection.get("wire_api") or "chat_completions"),
            "connection_id": cid,
        }
    providers = [item for item in config.get("providers", []) if isinstance(item, dict)]
    by_connection = {str(item.get("id")): item for item in connection_items}
    for provider in providers:
        identifier = str(provider.get("id") or "")
        if not identifier:
            continue
        cid = str(provider.get("connection_id") or "")
        if cid and cid in by_connection:
            provider_job[identifier] = f"connection:{cid}"
            continue
        if str(provider.get("kind") or "").lower() not in {"openai_compatible", "openai-compatible", "http"}:
            provider_job[identifier] = "local"
            continue
        base_url = str(provider.get("base_url") or "").strip()
        if not base_url:
            provider_job[identifier] = "unconfigured"
            continue
        try:
            api_key = resolve_api_key(provider)
        except Exception:
            api_key = ""
        fingerprint = hashlib.sha256(api_key.encode("utf-8")).hexdigest()[:12]
        key = f"legacy:{hashlib.sha256((normalized_url(base_url) + fingerprint).encode()).hexdigest()[:16]}"
        jobs.setdefault(key, {
            "base_url": base_url,
            "api_key": provider.get("api_key") or "",
            "api_key_file": provider.get("api_key_file") or "",
            "api_key_env": provider.get("api_key_env") or "",
            "wire_api": str(provider.get("wire_api") or "chat_completions"),
        })
        legacy_providers.setdefault(key, provider)
        provider_job[identifier] = key

    def run_probe(item: tuple[str, dict[str, Any]]) -> tuple[str, dict[str, Any]]:
        key, connection = item
        try:
            secret = resolve_api_key(connection)
        except Exception as exc:
            return key, {"ok": False, "status": "unreachable", "latency_ms": None,
                         "error": f"密钥读取失败：{type(exc).__name__}", "models": []}
        result = fetch_models(connection.get("base_url", ""), secret, connection.get("wire_api", "chat_completions"))
        # 保留 endpoint / address_matches / warning 等证据字段，只丢掉体积大的名单本体。
        check = {k: v for k, v in result.items() if k != "models"}
        check.setdefault("model_count", len(result.get("models") or []))
        return key, check

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, max(1, len(jobs)))) as pool:
        checks = dict(pool.map(run_probe, jobs.items())) if jobs else {}
    # 目录读不到名单时唯一还值得一试的兜底：拿一条模型发一次极小生成请求。
    # 只有「接口自己说没有 /models」才兜底：401 是凭据不对、超时是网络不通，这些情况下
    # 生成请求同样会失败，兜底只会白花 token。判据与 App 的 needsGenerationProbe 一致。
    fallback_targets = [(key, job) for key, job in jobs.items()
                        if (checks.get(key) or {}).get("ok") is not True
                        and (checks.get(key) or {}).get("catalog_unavailable") is True]
    if fallback_targets:
        def run_catalog_fallback(item: tuple[str, dict[str, Any]]) -> tuple[str, dict[str, Any] | None]:
            key, job = item
            cid = str(job.get("connection_id") or "")
            return key, catalog_fallback_check(
                by_connection.get(cid) if cid else None,
                legacy_providers.get(key),
                providers,
                by_connection,
                str((checks.get(key) or {}).get("error") or ""),
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(fallback_targets))) as pool:
            for key, answer in pool.map(run_catalog_fallback, fallback_targets):
                if not answer:
                    continue
                if answer.get("ok") is True:
                    checks[key] = answer
                else:
                    # 还是不通：保留原来的目录错误，再补上这次生成探测的证据。
                    checks[key] = {**checks[key], **answer}
    checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    provider_checks: dict[str, dict[str, Any]] = {}
    for provider in providers:
        identifier = str(provider.get("id") or "")
        job = provider_job.get(identifier)
        if job == "local":
            provider_checks[identifier] = {"status": "local", "ok": None, "latency_ms": None}
        elif job == "unconfigured":
            provider_checks[identifier] = {"status": "unconfigured", "ok": False, "latency_ms": None}
        elif job:
            provider_checks[identifier] = checks.get(job, {"status": "unreachable", "ok": False, "latency_ms": None})
    for identifier, check in provider_checks.items():
        job = jobs.get(provider_job.get(identifier, "")) or {}
        if is_loopback_url(job.get("base_url")):
            check["self_hosted"] = True
    for key, check in checks.items():
        job = jobs.get(key) or {}
        if is_loopback_url(job.get("base_url")):
            # 绿灯只说"这台机器上有服务在答"，不代表外部上游可用。
            check["self_hosted"] = True
            if check.get("ok") is True:
                check.setdefault("warning", "本机地址：只证明本机服务在应答，不能证明外部上游可用")
    payload = {"checked_at": checked_at, "connections": checks, "providers": provider_checks}
    target = Path(path or HEALTH_PATH)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(".json.tmp")
        temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(temp, 0o600)
        os.replace(temp, target)
    except OSError:
        pass
    return payload


GENERATION_PROBE_TIMEOUT = 45
GENERATION_PROBE_MAX_TOKENS = 8
GENERATION_PROBE_PROMPT = "只回一个字：好"
# 列表探测失败后的兜底要比正常探测快：用户正等着结果，20 秒能连上的线路才值得救回来。
CATALOG_FALLBACK_TIMEOUT = 20


def generation_text_from_payload(payload: Any, shape: str) -> tuple[str, str]:
    """从一次非流式生成响应里取出正文和结束原因；取不到就是取不到，不猜。"""
    if not isinstance(payload, dict):
        return "", ""
    if shape == "anthropic":
        parts = payload.get("content")
        if isinstance(parts, list):
            text = "".join(str(part.get("text") or "") for part in parts if isinstance(part, dict))
            return text, str(payload.get("stop_reason") or "")
        return "", ""
    choices = payload.get("choices")
    if isinstance(choices, list) and choices and isinstance(choices[0], dict):
        choice = choices[0]
        message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
        text = str(message.get("content") or choice.get("text") or "")
        return text, str(choice.get("finish_reason") or "")
    output = payload.get("output")
    if isinstance(output, list):
        chunks = []
        for item in output:
            if not isinstance(item, dict):
                continue
            for part in item.get("content") or []:
                if isinstance(part, dict):
                    chunks.append(str(part.get("text") or ""))
        return "".join(chunks), str(payload.get("status") or "")
    return "", ""


def error_code_and_message(raw: str) -> tuple[str, str]:
    try:
        payload = json.loads(raw or "{}")
    except ValueError:
        return "", (raw or "").strip()[:160]
    if not isinstance(payload, dict):
        return "", ""
    error = payload.get("error")
    if isinstance(error, dict):
        return str(error.get("code") or error.get("type") or ""), str(error.get("message") or "")
    if isinstance(error, str):
        return "", error
    return str(payload.get("code") or ""), str(payload.get("message") or "")


def generation_probe_target(
    provider: dict[str, Any], by_connection: dict[str, dict[str, Any]]
) -> tuple[str, str, str, str, str]:
    """(endpoint, secret, shape, base_url, 说明)；endpoint 为空表示这条线路发不出生成请求。"""
    kind = str(provider.get("kind") or "").lower()
    connection = by_connection.get(str(provider.get("connection_id") or ""))
    if connection is None and kind not in {"openai_compatible", "openai-compatible", "http"}:
        return "", "", "", "", f"非 HTTP 线路（{kind or '未填 kind'}），只能标未验证"
    source = connection or provider
    base_url = str(source.get("base_url") or provider.get("base_url") or "").strip()
    model = str(provider.get("model") or "").strip()
    if not base_url:
        return "", "", "", "", "缺少 base_url"
    if not model:
        return "", "", "", "", "缺少模型名"
    if is_anthropic_wire(provider) or (connection is not None and is_anthropic_wire(connection)):
        shape = "anthropic"
    elif is_responses_wire(provider) or (connection is not None and is_responses_wire(connection)):
        shape = "responses"
    else:
        shape = "chat"
    try:
        secret = resolve_api_key(source)
    except Exception as exc:
        return "", "", "", "", f"密钥读取失败：{type(exc).__name__}"
    if not secret and source is not provider:
        try:
            secret = resolve_api_key(provider)
        except Exception:
            secret = ""
    suffix = {"anthropic": "/messages", "responses": "/responses", "chat": "/chat/completions"}[shape]
    endpoint = base_url if base_url.endswith(suffix) else f"{base_url.rstrip('/')}{suffix}"
    return endpoint, secret, shape, base_url, ""


def strip_model_note(raw: Any) -> str:
    """去掉模型名后面的备注，如「glm-5.2（包月）」→「glm-5.2」；与 App 的 probeModelID 同一套规则。"""
    return re.sub(r"[（(][^）)]*[）)]\s*$", "", str(raw or "").strip()).strip()


def connection_probe_model(connection: dict[str, Any] | None,
                           providers: list[dict[str, Any]]) -> str:
    """兜底探测该报哪个模型名：先看这条线路启用的模型行，全关了再退回任意一行，
    最后才用连接目录里记的名字；挑不出来返回空串。
    顺序与 App 的 Connection.probeModelID 一致，两边探测同一台机器时结果不会互相打架。"""
    cid = str((connection or {}).get("id") or "")

    def first_name(raws: list[Any]) -> str:
        for raw in raws:
            name = strip_model_note(raw)
            if name:
                return name
        return ""

    rows = [row for row in providers
            if str(row.get("connection_id") or "") == cid and row.get("model")]
    picked = (first_name([row.get("model") for row in rows if row.get("enabled", True)])
              or first_name([row.get("model") for row in rows]))
    if picked:
        return picked
    catalog = (connection or {}).get("models")
    if isinstance(catalog, list):
        return first_name([row.get("id") or row.get("name") for row in catalog
                           if isinstance(row, dict) and row.get("enabled", True)])
    return ""


def post_generation_probe(endpoint: str, secret: str, shape: str, model: str,
                          timeout: float | None = None) -> dict[str, Any]:
    """发一次极小生成请求，只回报这次请求发生了什么，不替调用方下结论。

    键：http_ok（确实拿到 2xx 响应）、latency_ms、finish_reason、content_chars、has_text、error。
    验证模型要求真出字，连通兜底只要 2xx 就算线路活着——两处语义不同，所以这里只给事实。
    """
    if shape == "anthropic":
        body: dict[str, Any] = {
            "model": model,
            "max_tokens": GENERATION_PROBE_MAX_TOKENS,
            "messages": [{"role": "user", "content": GENERATION_PROBE_PROMPT}],
            "stream": False,
        }
    elif shape == "responses":
        body = {"model": model, "input": GENERATION_PROBE_PROMPT, "stream": False}
    else:
        body = {
            "model": model,
            "messages": [{"role": "user", "content": GENERATION_PROBE_PROMPT}],
            "max_tokens": GENERATION_PROBE_MAX_TOKENS,
            "temperature": 0,
            "stream": False,
        }
    headers = {"Content-Type": "application/json"}
    if secret:
        if shape == "anthropic":
            headers["x-api-key"] = secret
            headers["anthropic-version"] = "2023-06-01"
        else:
            headers["Authorization"] = f"Bearer {secret}"
    outcome: dict[str, Any] = {
        "http_ok": False,
        "latency_ms": None,
        "finish_reason": "",
        "content_chars": 0,
        "has_text": False,
        "error": "",
    }
    started = time.perf_counter()
    try:
        request = urllib.request.Request(
            endpoint, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=timeout or GENERATION_PROBE_TIMEOUT) as response:
            raw = response.read(1_000_001)
        payload = json.loads(raw.decode("utf-8", "replace"))
        text, finish = generation_text_from_payload(payload, shape)
        outcome.update({
            "http_ok": True,
            "latency_ms": round((time.perf_counter() - started) * 1000),
            "finish_reason": finish,
            "content_chars": len(text),
            "has_text": bool(text.strip()),
        })
    except urllib.error.HTTPError as exc:
        try:
            raw = exc.read(4096).decode("utf-8", "replace")
        except Exception:
            raw = ""
        code, message = error_code_and_message(raw)
        outcome.update({
            "latency_ms": round((time.perf_counter() - started) * 1000),
            "error": " · ".join(part for part in (f"HTTP {exc.code}", code, message[:160]) if part),
        })
    except urllib.error.URLError as exc:
        outcome["error"] = f"网络错误：{type(exc.reason).__name__}"
    except (TimeoutError, OSError) as exc:
        outcome["error"] = "连接超时" if isinstance(exc, TimeoutError) else "网络错误"
    except (ValueError, RuntimeError) as exc:
        outcome["error"] = str(exc)[:180]
    return outcome


def run_generation_probe(task: tuple[str, dict[str, Any], dict[str, dict[str, Any]]]) -> tuple[str, dict[str, Any]]:
    identifier, provider, by_connection = task
    endpoint, secret, shape, base_url, reason = generation_probe_target(provider, by_connection)
    model = str(provider.get("model") or "")
    check: dict[str, Any] = {
        "provider_id": identifier,
        "model": model,
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "self_hosted": is_loopback_url(base_url),
    }
    if not endpoint:
        check.update({"ok": None, "status": "skipped", "error": reason})
        return identifier, check
    check.update({"endpoint": endpoint, "shape": shape})
    outcome = post_generation_probe(endpoint, secret, shape, model)
    if not outcome["http_ok"]:
        check.update({"ok": False, "status": "error",
                      "latency_ms": outcome["latency_ms"], "error": outcome["error"]})
        return identifier, check
    has_text = bool(outcome["has_text"])
    check.update({
        "ok": has_text,
        "status": "verified" if has_text else "accepted-no-text",
        "latency_ms": outcome["latency_ms"],
        "finish_reason": outcome["finish_reason"],
        "content_chars": outcome["content_chars"],
        "error": "" if has_text else f"请求被接受，但没返回正文（finish_reason={outcome['finish_reason'] or '未知'}）",
    })
    return identifier, check


def catalog_fallback_check(
    connection: dict[str, Any] | None,
    provider: dict[str, Any] | None,
    providers: list[dict[str, Any]],
    by_connection: dict[str, dict[str, Any]],
    catalog_error: str,
) -> dict[str, Any] | None:
    """目录接口不在时改用一条极小生成请求验证线路；返回 None 表示这条线路不值得试。"""
    if connection is not None and str(connection.get("id") or ""):
        model = connection_probe_model(connection, providers)
        target: dict[str, Any] = {
            "kind": "openai_compatible",
            "connection_id": str(connection["id"]),
            "model": model,
        }
    elif provider is not None:
        model = strip_model_note(provider.get("model"))
        target = {**provider, "model": model}
    else:
        return None
    if not model:
        return None
    endpoint, secret, shape, base_url, _reason = generation_probe_target(target, by_connection)
    # 兜底只走 Chat Completions：这是最普遍的一条线，探测代码也最不容易误判。
    if not endpoint or shape != "chat":
        return None
    outcome = post_generation_probe(endpoint, secret, shape, model, timeout=CATALOG_FALLBACK_TIMEOUT)
    check: dict[str, Any] = {
        "endpoint": endpoint,
        "method": "generation",
        "probe_model": model,
        "latency_ms": outcome["latency_ms"],
        "self_hosted": is_loopback_url(base_url),
    }
    if outcome["http_ok"]:
        # 这里不要求出字：2xx 只说明这条线路活着；真要验「能不能出字」用「验证模型」。
        check.update({
            "ok": True,
            "status": "connected",
            "catalog_error": catalog_error,
            "error": "",
            # 名单没读到（接口根本没有 /models）：字段照样给，读数的人不必区分两种绿灯。
            "model_count": 0,
        })
        if outcome["finish_reason"]:
            check["finish_reason"] = outcome["finish_reason"]
    else:
        check.update({
            "ok": False,
            "status": "unreachable",
            "error": outcome["error"] or catalog_error,
        })
    return check


def probe_model_generation(
    config: dict[str, Any], provider_ids: list[str] | None = None, path: Path | None = None
) -> dict[str, Any]:
    """逐条 HTTP 线路发一次极小生成请求，验证它到底能不能出字；结果写进健康文件。"""
    connection_items = [item for item in config.get("connections", [])
                        if isinstance(item, dict) and item.get("id")]
    by_connection = {str(item["id"]): item for item in connection_items}
    providers = [item for item in config.get("providers", [])
                 if isinstance(item, dict) and item.get("id")]
    if provider_ids:
        wanted = {str(item) for item in provider_ids if str(item).strip()}
        providers = [item for item in providers if str(item["id"]) in wanted]
    tasks = [(str(item["id"]), item, by_connection) for item in providers]
    results: dict[str, dict[str, Any]] = {}
    if tasks:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(tasks))) as pool:
            results = dict(pool.map(run_generation_probe, tasks))
    checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    target = Path(path or HEALTH_PATH)
    payload = load_router_health(target)
    payload["models"] = results
    payload["models_checked_at"] = checked_at
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(".json.tmp")
        temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(temp, 0o600)
        os.replace(temp, target)
    except OSError:
        pass
    return {
        "checked_at": checked_at,
        "verified": sorted(name for name, item in results.items() if item.get("status") == "verified"),
        "failed": sorted(name for name, item in results.items() if item.get("status") == "error"),
        "skipped": sorted(name for name, item in results.items() if item.get("status") == "skipped"),
        "models": results,
    }


def model_fetch_self_test() -> int:
    """Offline assertion test for URL construction, auth headers, latency, catalog fallback and generation probes."""
    import tempfile
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    assert model_endpoint_candidates("https://api.example.test/v1") == [
        "https://api.example.test/v1/models"
    ]
    assert model_endpoint_candidates("https://ark.cn-beijing.volces.com/api/plan/v3") == [
        "https://ark.cn-beijing.volces.com/api/plan/v3/models",
        "https://ark.cn-beijing.volces.com/api/v3/models",
    ]
    assert model_endpoint_candidates("https://api.example.test/api/coding/paas/v4") == [
        "https://api.example.test/api/coding/paas/v4/models",
        "https://api.example.test/api/coding/paas/v4/v1/models",
    ]
    seen: list[tuple[str, bool]] = []
    generated: list[tuple[str, bool, str]] = []

    class Handler(BaseHTTPRequestHandler):
        def _send(self, payload: Any, code: int = 200) -> None:
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            seen.append((self.path, bool(self.headers.get("Authorization"))))
            if self.path == "/api/plan/v3/models":
                # 配置地址本身没有目录接口：名单只能由回退地址给出。
                self._send({"error": {"code": "NotFound", "message": "no catalog here"}}, 404)
                return
            if self.path.startswith("/reject/"):
                self._send({"error": {"code": "Unauthorized", "message": "bad key"}}, 401)
                return
            if self.path.startswith("/boom/"):
                self._send({"error": {"message": "upstream broke"}}, 500)
                return
            if self.path.startswith("/nocat"):
                # 这台服务根本不提供 /models，但生成接口是好的：只有这种线路才值得兜底。
                self._send({"error": {"code": "NotFound", "message": "no catalog here"}}, 404)
                return
            self._send({"data": [{"id": "model-a"}, {"id": "model-b"}]})

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            model = str(payload.get("model") or "")
            generated.append((self.path, bool(self.headers.get("Authorization")), model))
            if model == "model-b":
                self._send({"error": {"code": "ModelNotOpen", "message": "model not activated"}}, 404)
                return
            if model == "model-silent":
                # 请求被接受、一个字都没出：兜底只该认「线路活着」，「能不能出字」是验模型的事。
                self._send({"choices": [{"message": {"role": "assistant", "content": ""},
                                         "finish_reason": "stop"}]})
                return
            self._send({"choices": [{"message": {"role": "assistant", "content": "好"},
                                     "finish_reason": "stop"}]})

        def log_message(self, *_: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}/v1"
        result = fetch_models(base, "test-only-secret", "chat_completions")
        assert result["ok"] is True
        assert [item["id"] for item in result["models"]] == ["model-a", "model-b"]
        assert seen == [("/v1/models", True)]
        config = {
            "connections": [{"id": "test", "name": "Test", "base_url": base,
                             "api_key": "test-only-secret", "wire_api": "chat_completions"}],
            "providers": [{"id": "test-model", "connection_id": "test", "model": "model-a",
                           "kind": "openai_compatible"}],
            "agents": [{"id": "test-agent", "provider_ids": ["test-model"]}],
            "gateway": {"agent_id": "test-agent"},
        }
        with tempfile.TemporaryDirectory(prefix="ai-assistant-health-") as scratch:
            # 自检绝不碰真实的 router-health.json：以前它会写进 "connection:test" 这种幽灵行。
            health_path = Path(scratch) / "router-health.json"
            health = probe_all_connections(config, health_path)
            assert health["providers"]["test-model"]["ok"] is True
            assert "test-only-secret" not in json.dumps(health)
            assert health["connections"]["connection:test"]["self_hosted"] is True
            assert health["connections"]["connection:test"]["warning"]
            assert health_path.stat().st_mode & 0o777 == 0o600
            seen.clear()
            fallback = fetch_models(f"http://127.0.0.1:{server.server_port}/api/plan/v3",
                                    "test-only-secret", "chat_completions")
            assert fallback["ok"] is True and fallback["status"] == "catalog-only", fallback
            assert fallback["address_matches"] is False
            assert fallback["endpoint"].endswith("/api/v3/models")
            assert [item["id"] for item in fallback["models"]] == ["model-a", "model-b"]
            assert "尚未验证" in fallback["warning"]
            assert seen == [("/api/plan/v3/models", True), ("/api/v3/models", True)]
            generation = probe_model_generation(config, None, health_path)
            models = generation["models"]
            assert models["test-model"]["status"] == "verified", models["test-model"]
            assert models["test-model"]["ok"] is True and models["test-model"]["content_chars"] >= 1
            assert generation["verified"] == ["test-model"]
            assert generated == [("/v1/chat/completions", True, "model-a")], generated
            stored = json.loads(health_path.read_text(encoding="utf-8"))
            assert stored["models"]["test-model"]["status"] == "verified"
            assert "test-only-secret" not in health_path.read_text(encoding="utf-8")
            broken_config = {
                "connections": config["connections"],
                "providers": [{"id": "test-model", "connection_id": "test", "model": "model-b",
                               "kind": "openai_compatible"}],
            }
            broken = probe_model_generation(broken_config, None, health_path)["models"]["test-model"]
            assert broken["status"] == "error" and broken["ok"] is False, broken
            assert "ModelNotOpen" in broken["error"], broken
            skipped_config = {
                "connections": config["connections"],
                "providers": [{"id": "cmd-block", "kind": "command_block", "model": "model-a"}],
            }
            skipped = probe_model_generation(skipped_config, None, health_path)["models"]["cmd-block"]
            assert skipped["status"] == "skipped" and skipped["ok"] is None, skipped
            assert skipped["self_hosted"] is False
            # 目录接口不在时的兜底契约：何时试、何时绝不试、报哪个模型名、什么才算连上。
            port = server.server_port

            def probe_catalog(probed: dict[str, Any]) -> dict[str, Any]:
                generated.clear()
                seen.clear()
                return probe_all_connections(probed, health_path)

            no_catalog = f"http://127.0.0.1:{port}/nocat/v1"
            fallback = probe_catalog({
                "connections": [
                    {"id": "nocat", "name": "没有目录接口", "base_url": no_catalog,
                     "api_key": "key-nocat", "wire_api": "chat_completions"},
                    {"id": "silent", "name": "只答不出字", "base_url": f"http://127.0.0.1:{port}/nocat-silent/v1",
                     "api_key": "key-silent", "wire_api": "chat_completions",
                     "models": [{"id": "model-silent"}]},
                    {"id": "reject", "name": "凭据不对", "base_url": f"http://127.0.0.1:{port}/reject/v1",
                     "api_key": "key-reject", "wire_api": "chat_completions",
                     "models": [{"id": "model-a"}]},
                    {"id": "boom", "name": "上游出错", "base_url": f"http://127.0.0.1:{port}/boom/v1",
                     "api_key": "key-boom", "wire_api": "chat_completions",
                     "models": [{"id": "model-a"}]},
                    {"id": "anth", "name": "anthropic 协议", "base_url": f"http://127.0.0.1:{port}/nocat-anth/v1",
                     "api_key": "key-anth", "wire_api": "anthropic",
                     "models": [{"id": "model-a"}]},
                    {"id": "resp", "name": "responses 协议", "base_url": f"http://127.0.0.1:{port}/nocat-resp/v1",
                     "api_key": "key-resp", "wire_api": "responses",
                     "models": [{"id": "model-a"}]},
                ],
                "providers": [
                    {"id": "p-off", "connection_id": "nocat", "model": "model-off",
                     "enabled": False, "kind": "openai_compatible"},
                    {"id": "p-on", "connection_id": "nocat", "model": "model-a（包月）",
                     "kind": "openai_compatible"},
                ],
            })
            checks = fallback["connections"]
            nocat = checks["connection:nocat"]
            assert nocat["ok"] is True and nocat["status"] == "connected", nocat
            assert nocat["method"] == "generation" and nocat["model_count"] == 0
            # 目录那一步为什么失败要留档，用户才知道这盏绿灯是兜底来的。
            assert "/models" in nocat["catalog_error"], nocat
            assert nocat["error"] == ""
            assert fallback["providers"]["p-on"]["ok"] is True
            assert fallback["providers"]["p-off"]["ok"] is True
            # 报的是「启用的那一行」，而且剥掉了给人看的备注；密钥仍然带上。
            # 该兜底的两条线路各发一次；下面还会确认另外四条线路一次都没发。
            assert sorted(generated) == [("/nocat-silent/v1/chat/completions", True, "model-silent"),
                                         ("/nocat/v1/chat/completions", True, "model-a")], generated
            # 2xx 但一个字都没出：兜底只认「线路活着」，出不出字交给验模型。
            silent = checks["connection:silent"]
            assert silent["ok"] is True and silent["status"] == "connected", silent
            assert silent["finish_reason"] == "stop" and "content_chars" not in silent
            # 401 是凭据不对、500 是上游出错、另两种协议不换写法：这四种情况一次生成请求都不该发。
            for key, want in (("connection:reject", "401"), ("connection:boom", "500")):
                assert checks[key]["ok"] is False and checks[key]["status"] == "unreachable", checks[key]
                assert want in checks[key]["error"], checks[key]
            for key in ("connection:anth", "connection:resp"):
                assert checks[key]["ok"] is False and checks[key]["status"] == "unreachable", checks[key]
                assert checks[key]["catalog_unavailable"] is True, checks[key]
            assert sorted(generated) == [("/nocat-silent/v1/chat/completions", True, "model-silent"),
                                         ("/nocat/v1/chat/completions", True, "model-a")], generated
            assert all(checks[key]["catalog_unavailable"] is False
                       for key in ("connection:reject", "connection:boom")), checks
            # 目录读得到名单时，兜底绝不出场。
            healthy = probe_catalog(config)
            assert healthy["providers"]["test-model"]["ok"] is True
            assert generated == [], generated
            # 老式「只有 provider、没有连接」的线路走同一条兜底，模型名同样剥备注。
            legacy = probe_catalog({
                "connections": [],
                "providers": [{"id": "legacy-a", "base_url": no_catalog, "api_key": "key-legacy",
                               "wire_api": "chat_completions", "model": "model-a（包月）",
                               "kind": "openai_compatible"}],
            })
            assert legacy["providers"]["legacy-a"]["ok"] is True, legacy["providers"]["legacy-a"]
            assert legacy["providers"]["legacy-a"]["method"] == "generation"
            assert generated == [("/nocat/v1/chat/completions", True, "model-a")], generated
    finally:
        server.shutdown()
        server.server_close()
    print("model fetch self-test passed")
    return 0


def gateway_listen_self_test() -> int:
    """离线验证 `--serve` 的临时监听覆盖：真绑定、/health 报真话、绝不写回 router.json。"""
    import tempfile
    import urllib.error
    import urllib.request

    global BASE_DIR, CONFIG_PATH, CODEX_PICKER_CATALOG_PATH
    saved = (BASE_DIR, CONFIG_PATH)
    with tempfile.TemporaryDirectory(prefix="ai-assistant-gateway-listen-") as temporary:
        root = Path(temporary)
        BASE_DIR = root
        CONFIG_PATH = root / "router.json"
        old_picker_catalog = CODEX_PICKER_CATALOG_PATH
        CODEX_PICKER_CATALOG_PATH = root / "catalog.json"
        try:
            CODEX_PICKER_CATALOG_PATH.write_text(
                json.dumps({"models": [{"slug": "self-test-model", "visibility": "list"}]}),
                encoding="utf-8",
            )
            write_config(
                {
                    "version": 1,
                    "gateway": {"host": "127.0.0.1", "port": 4321, "agent_id": "omni"},
                    "connections": [
                        {
                            "id": "conn-self-test",
                            "name": "自检线路",
                            "base_url": "http://127.0.0.1:9/v1",
                            "api_key": "self-test-key",
                            "wire_api": "chat_completions",
                            "enabled": True,
                        }
                    ],
                    "providers": [
                        {
                            "id": "prov-self-test",
                            "connection_id": "conn-self-test",
                            "model": "self-test-model",
                            "enabled": True,
                        }
                    ],
                    "agents": [
                        {"id": "default", "provider_ids": ["prov-self-test"]},
                        {"id": "omni", "provider_ids": ["prov-self-test"]},
                    ],
                }
            )
            key = ensure_gateway_key(ensure_config())
            before = CONFIG_PATH.read_bytes()

            # ① 参数校验：坏参数要在启动前用人话拦下，不许把服务带进半死状态
            for bad in ({"port": "abc"}, {"port": "70000"}, {"port": "-1"}, {"host": "   "}, {"agent_id": "  "}):
                try:
                    gateway_overrides({}, **bad)
                except RuntimeError:
                    continue
                raise AssertionError(f"这些参数本来就该被拦下：{bad}")

            # ② 真绑定：--port 0 = 让系统挑空闲端口，报出来的必须是挑中的那个
            settings = gateway_settings(ensure_config())
            _, requested_port, overrides = gateway_overrides(settings, "127.0.0.1", 0, "default")
            assert requested_port == 0
            server, effective, base_url = open_gateway(settings, overrides)
            real_port = int(server.server_address[1])
            assert real_port > 0, "系统该挑到一个真端口"
            assert base_url == f"http://127.0.0.1:{real_port}/v1", base_url
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                # /health 报的地址必须就是真在听的地址：外层端口闸门只信这一个信源
                health = json.loads(
                    urllib.request.urlopen(f"{base_url}/health", timeout=5).read().decode("utf-8")
                )
                assert health["status"] == "ok", health
                assert health["gateway"] == base_url, health
                # 覆盖的 Agent 也要跟着生效（配置里写的是 omni，这次跑的是 default）
                assert health["agent"] == "default", health
                assert settings.get("agent_id") == "omni", "覆盖不该改到盘上的设置"

                listing = json.loads(
                    urllib.request.urlopen(
                        urllib.request.Request(
                            f"{base_url}/models", headers={"Authorization": f"Bearer {key}"}
                        ),
                        timeout=5,
                    )
                    .read()
                    .decode("utf-8")
                )
                # default Agent 的目录与 Codex picker 共用；客户端照这份单子点菜，不能 400。
                advertised = [item["id"] for item in listing["data"]]
                routed_agent, routed = gateway_routes(ensure_config(), "default")
                assert routed_agent == "default", listing
                assert advertised == ["self-test-model"], listing
                assert advertised and all(
                    any(
                        name in {str(provider.get("id") or ""), str(provider.get("model") or ""),
                                 external_model_name(provider)}
                        for provider in routed
                    )
                    for name in advertised[1:]
                ), f"报了 POST 不认的模型名：{advertised} / {listing}"
                try:
                    urllib.request.urlopen(f"{base_url}/models", timeout=5)
                except urllib.error.HTTPError as exc:
                    assert exc.code == 401, exc.code
                except urllib.error.URLError as exc:
                    raise AssertionError(f"没带密钥的 /v1/models 该回 401，而不是断连：{exc}") from exc
                else:
                    raise AssertionError("没带密钥的 /v1/models 该被拒")
            finally:
                server.shutdown()
                server.server_close()

            # ③ 覆盖只活在这个进程里：router.json 一个字节都不能变
            assert CONFIG_PATH.read_bytes() == before, "临时覆盖被写回 router.json 了"
            # ④ 退出（清掉覆盖）后，视图回到盘上的真实设置
            GATEWAY_OVERRIDES.clear()
            assert int(gateway_view()["gateway"]["port"]) == 4321
            assert gateway_info(gateway_view())["base_url"] == "http://127.0.0.1:4321/v1"
        finally:
            GATEWAY_OVERRIDES.clear()
            CODEX_PICKER_CATALOG_PATH = old_picker_catalog
            BASE_DIR, CONFIG_PATH = saved
    print("gateway listen self-test passed")
    return 0


def discover_external_agents() -> dict[str, Any]:
    """Read known local client configs without reading or returning secrets."""
    home = Path.home()
    agents: list[dict[str, Any]] = []

    def add(client: str, path: Path, models: list[str], current: str = "", details: str = "") -> None:
        agents.append({
            "client": client,
            "path": str(path),
            "models": list(dict.fromkeys([item for item in models if item])),
            "current_model": current,
            "details": details,
        })

    zcode = home / ".zcode/v2/config.json"
    try:
        payload = json.loads(zcode.read_text(encoding="utf-8"))
        models: list[str] = []
        for provider in (payload.get("provider") or {}).values():
            if not isinstance(provider, dict):
                continue
            prefix = str(provider.get("name") or "供应商")
            for model_id in (provider.get("models") or {}).keys():
                models.append(f"{prefix} / {model_id}")
        add("ZCode", zcode, models, details="配置可读；当前聊天模型由 ZCode 会话选择器管理")
    except (OSError, ValueError, TypeError):
        pass

    codex = home / ".codex/config.toml"
    try:
        text = codex.read_text(encoding="utf-8")
        sections = parse_toml_fragment(text)
        current = str(sections.get("", {}).get("model") or "")
        models = [current] if current else []
        models.extend(str(values.get("name") or name.split(".", 1)[-1]) for name, values in sections.items() if name.startswith("model_providers."))
        add("Codex", codex, models, current, "用户级 config.toml")
    except OSError:
        pass

    for client, path, keys in (
        ("Claude Code", home / ".claude/settings.json", ("ANTHROPIC_MODEL", "model")),
        ("Claude Code（本地设置）", home / ".claude/settings.local.json", ("ANTHROPIC_MODEL", "model")),
    ):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            env = payload.get("env") if isinstance(payload.get("env"), dict) else {}
            current = next((str(env.get(key) or payload.get(key) or "") for key in keys if env.get(key) or payload.get(key)), "")
            add(client, path, [current] if current else [], current, "配置可读")
        except (OSError, ValueError, TypeError):
            pass

    opencode = home / ".config/opencode/opencode.json"
    try:
        payload = json.loads(opencode.read_text(encoding="utf-8"))
        models = []
        for provider in (payload.get("provider") or {}).values():
            if isinstance(provider, dict):
                models.extend(str(item) for item in (provider.get("models") or {}).keys())
        add("OpenCode", opencode, models, str(payload.get("model") or ""), "配置可读")
    except (OSError, ValueError, TypeError):
        pass

    return {"agents": agents, "scanned_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}


def backup_file(path: Path) -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.ai-assistant-backup-{stamp}")
    backup.write_bytes(path.read_bytes())
    return str(backup)


CLIENT_AGENT_LABELS = {
    "codex": "Codex",
    "zcode": "ZCode",
    "opencode": "OpenCode",
    "claude": "Claude Code",
}


# ---------------------------------------------------------------- 三类 id
# 界面、脚本、导出件说的必须是同一件事，所以先把三类 id 分清楚：
#   ① router.json 的 agents[].id —— 网关侧的 Agent，授权对象是它的线路表
#   ② clients.json 的条目 id —— 界面上能增删的客户端，只回答「界面盯着哪几个客户端」
#   ③ 本地真检测到的客户端（discover_external_agents）—— 只读：认得出，但不许写
# 写入侧白名单 = ① ∪ ②。③ 和任何陌生 id 一律报错：绝不回落到 default 猜着写。
# 种子要和 Swift 的 HubClientRegistry.seed 对齐（要么两处都改，要么都别改）。
CLIENT_REGISTRY_SEED: list[dict[str, Any]] = [
    {"id": "codex", "name": "Codex", "path": "~/.codex/config.toml", "editable": True},
    {"id": "zcode", "name": "ZCode", "path": "~/.zcode/v2/config.json", "editable": True},
    {"id": "claude", "name": "Claude Code", "path": "~/.claude/settings.json", "editable": True},
    {"id": "opencode", "name": "OpenCode", "path": "~/.config/opencode/opencode.json", "editable": True},
]
ID_KIND_LABELS = {"router": "①", "client": "②", "detected": "③"}


def _warn(message: str) -> None:
    """提醒但不拦路：只用于「空 id，按客户端自己的 Agent 处理」这类可继续的情况。"""
    print(f"提示：{message}", file=sys.stderr)


def client_registry_path() -> Path:
    """清单路径每次都现算：自检会把 BASE_DIR 挪进临时目录。"""
    return Path(BASE_DIR) / "clients.json"


def read_client_registry() -> list[dict[str, Any]]:
    """读 ② 客户端清单（clients.json）。读不到 / 坏掉 / 空 → 内置种子。

    故意不缓存：界面上删掉或改过一个客户端，下一次调用立刻就是新结果。
    """
    try:
        rows = json.loads(client_registry_path().read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        rows = []
    cleaned: list[dict[str, Any]] = []
    seen: set[str] = set()
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            cid = str(row.get("id") or "").strip()
            path = str(row.get("path") or "").strip()
            if not (cid and path) or cid in seen:
                continue
            seen.add(cid)
            cleaned.append({
                "id": cid,
                "name": str(row.get("name") or "").strip() or cid,
                "path": path,
                "editable": bool(row.get("editable")),
            })
    return cleaned or [dict(row) for row in CLIENT_REGISTRY_SEED]


def expand_client_path(path: str) -> str:
    """展开 ~ 并解析成绝对路径的字面值，用来做路径比对（不做网络/磁盘探测）。"""
    return str(Path(os.path.expanduser(str(path or ""))).resolve()) if str(path or "").strip() else ""


def client_spec(wanted: str = "", path: str = "") -> dict[str, Any] | None:
    """在 ② 清单里按 id / 名字 / 配置文件路径找条目；找不到返回 None（绝不猜）。"""
    name = str(wanted or "").strip().lower()
    target = expand_client_path(path)
    registry = read_client_registry()
    for spec in registry:
        if name and name in {str(spec["id"]).lower(), str(spec["name"]).lower()}:
            return spec
    if target:
        for spec in registry:
            if expand_client_path(spec["path"]) == target:
                return spec
    return None


def client_assignment_models(config: dict[str, Any], client: str) -> list[str]:
    """读客户端自己的模型分配；旧 router.json 没这段时返回空列表。"""
    assignments = config.get("client_assignments")
    if not isinstance(assignments, dict):
        return []
    values = assignments.get(str(client or "").strip().lower())
    if not isinstance(values, list):
        return []
    result: list[str] = []
    for value in values:
        model = str(value or "").strip()
        if model and model not in result:
            result.append(model)
    return result


def assign_client_model(config: dict[str, Any], client: str, model: str) -> bool:
    """把模型加到客户端分配表；只改 router.json 的控制层，不碰客户端根键。"""
    client_id = str(client or "").strip().lower()
    value = str(model or "").strip()
    if not client_id or not value:
        return False
    assignments = config.setdefault("client_assignments", {})
    if not isinstance(assignments, dict):
        assignments = {}
        config["client_assignments"] = assignments
    values = assignments.setdefault(client_id, [])
    if not isinstance(values, list):
        values = []
        assignments[client_id] = values
    if value in values:
        return False
    values.append(value)
    return True


def detected_clients() -> dict[str, dict[str, Any]]:
    """③ 本地真检测到的客户端，按展开后的路径归类。只读，失败也不拖垮导出。"""
    found: dict[str, dict[str, Any]] = {}
    try:
        scan = discover_external_agents()
    except Exception:  # noqa: BLE001 - 扫描是锦上添花，不许影响导出
        return found
    for row in scan.get("agents") or []:
        if not isinstance(row, dict) or not str(row.get("path") or "").strip():
            continue
        name = str(row.get("client") or "")
        found[expand_client_path(str(row["path"]))] = {
            "id": slugify(name) or slugify(Path(str(row["path"])).stem) or "detected",
            "name": name or Path(str(row["path"])).stem,
            "path": str(row["path"]),
            "models": [str(item) for item in (row.get("models") or [])],
            "current_model": str(row.get("current_model") or ""),
        }
    return found


def writable_client_ids(config: dict[str, Any]) -> set[str]:
    """写入侧白名单 = ① router.json 的 Agent id ∪ ② clients.json 的客户端 id。"""
    ids = {
        str(agent.get("id"))
        for agent in (config.get("agents") or [])
        if isinstance(agent, dict) and agent.get("id")
    }
    ids |= {str(spec["id"]) for spec in read_client_registry()}
    return ids


def validate_write_id(config: dict[str, Any], requested: str, fallback: str = "") -> tuple[str, str]:
    """写入前唯一的收窄口。返回 (id, 警告语)：警告语非空 = 只提醒，不算错。

    - 白名单里（① 或 ②）→ 放行
    - 白名单外 → 直接报错，并且不回落：宁可让人看见失败，也不能写错 Agent
    - 空 id → 不报错，按「客户端自己的 Agent」处理，只给一句提醒
    """
    wanted = str(requested or "").strip()
    if not wanted:
        target = str(fallback or "").strip() or "default"
        return target, f"没指定客户端 id，按客户端自己的 Agent「{target}」处理"
    allowed = writable_client_ids(config)
    if wanted not in allowed:
        raise RuntimeError(
            f"客户端 id「{wanted}」不在白名单里（白名单 = ① router.json 的 Agent + ② clients.json 的客户端）；"
            f"可用的是 {sorted(allowed)}。先把客户端加进清单再来写，不猜。"
        )
    return wanted, ""


def find_agent_exact(config: dict[str, Any], agent_id: str) -> dict[str, Any] | None:
    """精确查 Agent，不做任何回落。

    find_agent 找不到会回落到 default（脚本/快捷指令对 id 打错字的容错），
    但写入路径绝对不能吃这个容错：那会把「给 A 客户端」的线路悄悄写进 default。
    """
    wanted = str(agent_id or "").strip()
    for agent in config.get("agents") or []:
        if isinstance(agent, dict) and str(agent.get("id")) == wanted:
            return agent
    return None


def gateway_url_for(config: dict[str, Any], agent_id: str) -> str:
    """这个 Agent 在本地网关上的地址：客户端文件里只许写地址，不写上游。"""
    port = int(gateway_settings(config).get("port") or GATEWAY_DEFAULT_PORT)
    return f"http://127.0.0.1:{port}/agents/{quote(str(agent_id), safe='')}/v1"


def writer_for_path(target: Path) -> str:
    """按已知客户端路径选写入器；陌生 JSON 绝不猜着改。"""
    path = str(target).lower()
    if target.suffix.lower() == ".toml" and "/.codex/" in path:
        return "codex"
    if target.suffix.lower() == ".json" and "/.zcode/" in path:
        return "zcode"
    if target.suffix.lower() == ".json" and "/.config/opencode/" in path:
        return "opencode"
    if target.suffix.lower() == ".json" and "/.claude/" in path:
        return "claude"
    raise RuntimeError(f"认不出 {target.name} 的客户端格式：不改，也不猜")


def _merged_row(*, primary: str, name: str, path: str, editable: bool, router_id: str,
                client_id: str, detected_id: str, models: list[str], current: str,
                config: dict[str, Any]) -> dict[str, Any]:
    """一行 = 一个客户端/Agent，同时带上三类 id（没有的那类留空字符串）。"""
    row_id = {"router": router_id, "client": client_id, "detected": detected_id}[primary]
    writable = bool(editable) and primary in {"router", "client"}
    reason = ""
    if primary == "detected":
        reason = "③ 只读：本地检测到，但不在 clients.json 清单里 —— 先加进清单再谈写入"
    elif not editable and primary == "client":
        reason = "清单里标着不可写（editable = false）：界面不许假装能改它"
    return {
        "id": row_id,
        "kind": primary,
        "kind_label": ID_KIND_LABELS[primary],
        "ids": {"router": router_id, "client": client_id, "detected": detected_id},
        "name": name,
        "path": path,
        "editable": bool(editable),
        "writable": writable,
        "reason": reason,
        "models": [str(item) for item in models if item],
        "current_model": str(current or ""),
        "gateway_base_url": gateway_url_for(config, row_id) if row_id else "",
    }


def agent_rows(config: dict[str, Any]) -> list[dict[str, Any]]:
    """三类 id 合成一张表：② 为主干，挂上路径/名字对得上的 ③ 和同名 ①；剩下的各成一行。"""
    registry = read_client_registry()
    detected = detected_clients()
    router = {str(a.get("id")): a for a in (config.get("agents") or [])
              if isinstance(a, dict) and a.get("id")}
    used_detected: set[str] = set()
    used_router: set[str] = set()
    rows: list[dict[str, Any]] = []
    for spec in registry:
        key = expand_client_path(spec["path"])
        found = detected.get(key)
        if found:
            used_detected.add(key)
        router_id = str(spec["id"]) if str(spec["id"]) in router else ""
        if router_id:
            used_router.add(router_id)
        rows.append(_merged_row(
            primary="client", name=str(spec["name"]), path=str(spec["path"]),
            editable=bool(spec["editable"]), router_id=router_id, client_id=str(spec["id"]),
            detected_id=str(found["id"]) if found else "",
            models=(found or {}).get("models") or [],
            current=str((found or {}).get("current_model") or ""), config=config,
        ))
    for key, found in detected.items():
        if key in used_detected:
            continue
        rows.append(_merged_row(
            primary="detected", name=str(found["name"]), path=str(found["path"]), editable=False,
            router_id="", client_id="", detected_id=str(found["id"]),
            models=found["models"], current=found["current_model"], config=config,
        ))
    for rid, agent in router.items():
        if rid in used_router:
            continue
        rows.append(_merged_row(
            primary="router", name=str(agent.get("name") or rid), path="", editable=False,
            router_id=rid, client_id="", detected_id="",
            models=[str(p.get("model")) for p in providers_for_agent(config, rid) if p.get("model")],
            current="", config=config,
        ))
    return rows


def export_agents(config: dict[str, Any]) -> dict[str, Any]:
    """--agents --export 的正文：三类 id 一张表，只读，绝不写盘。"""
    import copy

    # 只读就该有只读的样子：下面那些 helper 会补默认值（gateway.enabled 之类），
    # 在副本上补，别把调用方手里的配置悄悄改掉。
    config = copy.deepcopy(config)
    rows = agent_rows(config)
    counts = {kind: sum(1 for row in rows if row["kind"] == kind) for kind in ID_KIND_LABELS}
    counts["total"] = len(rows)
    return {
        "version": 1,
        "scanned_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "registry_path": str(client_registry_path()),
        "router_path": str(CONFIG_PATH),
        "kinds": {
            "router": "① router.json 的 agents[].id（网关侧 Agent）",
            "client": "② clients.json 的客户端条目（界面可增删）",
            "detected": "③ 本地检测到的客户端（只读）",
        },
        "whitelist": {
            "note": "写入侧白名单 = ① ∪ ②；③ 只读，不在里面",
            "ids": sorted(writable_client_ids(config)),
        },
        "counts": counts,
        "clients": rows,
    }


def agent_model_rows(config: dict[str, Any], only_agent: str = "") -> list[dict[str, Any]]:
    """每个 Agent 的每条线路一行。base_url 必须是真地址（连接里那条），不许拿连接名充数。"""
    connections = {str(row.get("id")): row for row in (config.get("connections") or [])
                   if isinstance(row, dict) and row.get("id")}
    providers = {str(row.get("id")): row for row in (config.get("providers") or [])
                 if isinstance(row, dict) and row.get("id")}
    wanted_agent = str(only_agent or "").strip()
    if wanted_agent:
        known = [str(item.get("id")) for item in config.get("agents") or []
                 if isinstance(item, dict) and item.get("id")]
        if wanted_agent not in known:
            # 空表最容易被当成「这个 Agent 没有线路」：找不到就直说，别拿空结果糊弄。
            raise RuntimeError(f"配置里没有 Agent「{wanted_agent}」：有 {known}。不猜。")
    rows: list[dict[str, Any]] = []
    for agent in config.get("agents") or []:
        if not isinstance(agent, dict):
            continue
        agent_id = str(agent.get("id") or "")
        if not agent_id or (wanted_agent and agent_id != wanted_agent):
            continue
        for provider_id in agent.get("provider_ids") or []:
            provider = providers.get(str(provider_id))
            row = {
                "agent_id": agent_id,
                "agent_name": str(agent.get("name") or agent_id),
                "provider_id": str(provider_id),
                "provider_name": "",
                "model": "",
                "base_url": "",
                "wire_api": "",
                "connection_id": "",
                "connection_name": "",
                "gateway_base_url": gateway_url_for(config, agent_id),
                "enabled": False,
                "source": "",
                "error": "",
            }
            if provider is None:
                row["error"] = "这条线路已经不在供应商池里了：去模型池清理一下"
                rows.append(row)
                continue
            connection = connections.get(str(provider.get("connection_id"))) or {}
            base_url = str(provider.get("base_url") or connection.get("base_url") or "").strip()
            row.update({
                "provider_name": str(provider.get("name") or ""),
                "model": external_model_name(provider),
                "base_url": base_url,
                "wire_api": str(provider.get("wire_api") or connection.get("wire_api") or ""),
                "connection_id": str(provider.get("connection_id") or ""),
                "connection_name": str(connection.get("name") or ""),
                "enabled": bool(provider.get("enabled", True)) and bool(connection.get("enabled", True)),
                "source": str(provider.get("source") or ""),
            })
            if not base_url:
                row["error"] = "线路没配地址：去模型池把 Base URL 补上"
            elif not base_url.startswith(("http://", "https://")):
                row["error"] = "线路地址不是 http(s) URL：模型池里那条填错了"
            elif not row["model"]:
                row["error"] = "线路没配模型名：模型池里那条不完整"
            rows.append(row)
    return rows


def render_id_table(rows: list[dict[str, Any]]) -> str:
    """人看的表：三个类别各在哪一行一眼可见。"""
    lines = ["类别   id                      名字                 可写  配置文件"]
    for row in rows:
        lines.append("{kind:<5} {id:<23} {name:<20} {writable:<5} {path}".format(
            kind=row["kind_label"], id=row["id"], name=row["name"][:19],
            writable="是" if row["writable"] else "否", path=row["path"] or "-"))
    return "\n".join(lines)


def render_model_table(rows: list[dict[str, Any]]) -> str:
    lines = ["Agent       模型                地址（真地址，不是连接名）"]
    for row in rows:
        lines.append("{agent:<11} {model:<19} {url}{flag}".format(
            agent=row["agent_id"][:10], model=(row["model"] or "(无模型名)")[:18],
            url=row["base_url"] or "(没配地址)", flag="" if not row["error"] else f"  ← {row['error']}"))
    return "\n".join(lines)


def unique_row_id(rows: list[Any], base: str) -> str:
    """生成一个未被占用的 id：后来的行绝不覆盖先前的行。"""
    taken = {str(item.get("id")) for item in rows if isinstance(item, dict)}
    candidate = slugify(base) or "row"
    if candidate not in taken:
        return candidate
    counter = 2
    while f"{candidate}-{counter}" in taken:
        counter += 1
    return f"{candidate}-{counter}"


def sync_external_agent(config: dict[str, Any], client: str, path: str, agent_id: str,
                        preferred_model: str = "", exact_agent: bool = False,
                        route_only: bool = False) -> dict[str, Any]:
    """Point one external client at the local per-Agent gateway path.

    所有 Agent 客户端都写入各自的 AI助手 default Agent 地址（4230）。
    4202 只由语音助手的 Jev/模型策略链单独使用，不再作为 Codex 的客户端出口。
    「加模型」仍然只更新 router.json 的客户端分配表；真正的网关接管由
    --sync-agent 负责写入客户端配置。
    preferred_model 是刚选中的模型：它排在清单最前。
    每次写盘前先备份。

    exact_agent = True 时 Agent 必须精确存在，不许回落到 default：写入路径专用，
    免得「给 A 客户端」的线路悄悄落到别的 Agent 上。
    """
    target = Path(os.path.expanduser(path)).resolve()
    if not target.exists():
        raise RuntimeError(f"找不到客户端配置：{target}")
    # 写哪个客户端由文件格式说了算，id 只是标签：新加的客户端条目也能直接写。
    writer = writer_for_path(target)
    if writer == "claude" and client != "claude":
        raise RuntimeError(f"{target.name} 是 Claude Code 配置，不是客户端「{client}」：拒绝改别的软件")
    codex_existing_model = ""
    if writer == "codex" and client == "codex":
        try:
            codex_text = target.read_text(encoding="utf-8")
            codex_sections = parse_toml_fragment(codex_text)
            codex_existing_model = str(codex_sections.get("", {}).get("model") or "").strip()
            # 旧版/带外部扩展的 config.toml 可能让轻量解析器不返回根表；
            # 迁移到 4230 时必须保留当前模型，不能静默退回 default 第一项。
            if not codex_existing_model:
                root = codex_text.split("\n[", 1)[0]
                match = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', root)
                codex_existing_model = match.group(1).strip() if match else ""
        except OSError:
            codex_existing_model = ""
    if writer == "codex" and client == "codex" and route_only:
        assigned = client_assignment_models(config, "codex")
        selected = str(preferred_model or "").strip()
        models = [selected] + [model for model in assigned if model != selected] if selected else assigned
        current = codex_existing_model if codex_existing_model else (models[0] if models else "")
        return {
            "client": client,
            "writer": writer,
            "path": str(target),
            "agent": "codex",
            "agent_name": "Codex",
            "base_url": "http://127.0.0.1:4202/v1",
            "models": models,
            "current_model": current,
            "backup": None,
        }
    if exact_agent:
        agent = find_agent_exact(config, agent_id)
        if agent is None:
            raise RuntimeError(
                f"配置里没有 Agent「{agent_id}」：拒绝改写 {target.name}，也不回落到 default"
            )
    else:
        agent = find_agent(config, agent_id)
    resolved_agent = str(agent.get("id") or agent_id)
    key = ensure_gateway_key(config)
    base_url = gateway_url_for(config, resolved_agent)
    models = [
        external_model_name(provider) or str(provider.get("id"))
        for provider in external_model_catalog(providers_for_agent(config, resolved_agent))
        if provider.get("model") or provider.get("id")
    ]
    selected = str(preferred_model or "").strip()
    if selected:
        models = [selected] + [model for model in models if model != selected]
    if not models:
        raise RuntimeError(f"Agent「{resolved_agent}」没有已启用模型")
    # 迁移到 4230 后，Codex 当前模型必须属于 default Agent 的真实目录；
    # 旧的 gpt-6-luna 等 4202 内部模型不能继续伪装成 4230 可用模型。
    # 不在目录里的旧值自动落到首个已启用模型（通常是 deepseek-flash）。
    if writer == "codex" and codex_existing_model:
        current = next((item for item in models
                        if item.casefold() == codex_existing_model.casefold()), models[0])
    else:
        current = models[0]
    if current:
        models = [current] + [model for model in models if model != current]
    backup = backup_file(target)
    if writer == "zcode":
        payload = json.loads(target.read_text(encoding="utf-8"))
        provider_map = payload.setdefault("provider", {})
        provider_id = f"ai-assistant-{slugify(resolved_agent)}"
        provider_map[provider_id] = {
            "name": f"AI助手 · {agent.get('name') or resolved_agent}",
            "kind": "openai",
            "source": "custom",
            "options": {"baseURL": base_url, "apiKey": key, "apiKeyRequired": True},
            "models": {model: {"limit": {"context": 1000000, "output": 128000}, "modalities": {"input": ["text"], "output": ["text"]}} for model in models},
        }
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    elif writer == "opencode":
        text = target.read_text(encoding="utf-8").strip()
        try:
            payload = json.loads(text) if text else {}
        except ValueError as error:
            raise RuntimeError(f"{target.name} 不是合法 JSON：不改") from error
        if not isinstance(payload, dict):
            raise RuntimeError(f"{target.name} 顶层不是 JSON 对象：不改")
        provider_map = payload.setdefault("provider", {})
        if not isinstance(provider_map, dict):
            raise RuntimeError(f"{target.name} 的 provider 不是对象：不改")
        provider_id = f"ai-assistant-{slugify(resolved_agent)}"
        provider_map[provider_id] = {
            "name": f"AI助手 · {agent.get('name') or resolved_agent}",
            "options": {"baseURL": base_url, "apiKey": key},
            "models": {model: {} for model in models},
        }
        if not str(payload.get("model") or "").strip():
            payload["model"] = f"{provider_id}/{current}"
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    elif writer == "claude":
        text = target.read_text(encoding="utf-8").strip()
        try:
            payload = json.loads(text) if text else {}
        except ValueError as error:
            raise RuntimeError(f"{target.name} 不是合法 JSON：不改") from error
        if not isinstance(payload, dict):
            raise RuntimeError(f"{target.name} 顶层不是 JSON 对象：不改")
        env = payload.setdefault("env", {})
        if not isinstance(env, dict):
            raise RuntimeError(f"{target.name} 的 env 不是对象：不改")
        env.update({
            "ANTHROPIC_BASE_URL": base_url,
            "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_MODEL": current,
        })
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    elif writer == "codex":
        text = target.read_text(encoding="utf-8")
        provider_id = f"ai_assistant_{slugify(resolved_agent).replace('-', '_')}"
        scalar = f'model_provider = "{provider_id}"\nmodel = "{current}"'
        # Codex 仍可能读取旧的根级 openai_base_url；只改 provider 表会造成
        # UI 显示 4230、实际请求仍落到 4202。统一把两个入口都指向 default Agent。
        root_base = f'openai_base_url = "{base_url}"'
        if re.search(r"(?m)^openai_base_url\s*=", text):
            text = re.sub(r"(?m)^openai_base_url\s*=.*$", root_base, text)
        else:
            text = root_base + "\n" + text
        text = re.sub(r"(?m)^model_provider\s*=.*$", "", text)
        text = re.sub(r"(?m)^model\s*=.*$", "", text)
        existing = rf"(?ms)^\[model_providers\.{re.escape(provider_id)}\]\n.*?(?=^\[|\Z)"
        text = re.sub(existing, "", text)
        section = (
            f'\n[model_providers.{provider_id}]\n'
            f'name = "AI助手 · {agent.get("name") or resolved_agent}"\n'
            f'base_url = "{base_url}"\nrequires_openai_auth = true\nwire_api = "responses"\n'
            f'experimental_bearer_token = "{key}"\n'
        )
        target.write_text(scalar + "\n" + text.lstrip() + section, encoding="utf-8")
    else:
        raise RuntimeError(f"暂不支持自动写入 {target.name}")
    return {
        "client": client,
        "writer": writer,
        "path": str(target),
        "agent": resolved_agent,
        "agent_name": str(agent.get("name") or resolved_agent),
        "base_url": base_url,
        "models": models,
        "current_model": current,
        "backup": backup,
    }


def resolve_supplier_row(config: dict[str, Any], provider_id: str, provider_name: str,
                         provider_url: str, provider_key: str, provider_wire: str,
                         model: str) -> tuple[dict[str, Any], bool]:
    """找到要绑进 Agent 的供应商池线路；返回 (线路行, 是否是这次新建的)。

    新界面走 --provider-id：直接用「模型池」里已经配好的线路，绝不复制第二份配置。
    旧命令只给名称/地址/Key 时，按地址复用连接、按模型名复用线路行。
    """
    wanted = str(provider_id or "").strip()
    if wanted:
        for row in config.get("providers") or []:
            if isinstance(row, dict) and str(row.get("id")) == wanted:
                return row, False
        raise RuntimeError(f"供应商池里没有线路 {wanted}：先刷新模型池，再来添加")
    url = str(provider_url or "").strip().rstrip("/")
    if not url:
        raise RuntimeError("缺少 --provider-id，也没有可用的 --provider-url")
    chosen = str(model or "").strip()
    if not chosen:
        raise RuntimeError("缺少模型名：--model")
    name = str(provider_name or "").strip() or url
    connections = config.setdefault("connections", [])
    connection = None
    for item in connections:
        if isinstance(item, dict) and normalized_url(item.get("base_url")) == normalized_url(url):
            connection = item
            break
    if connection is None:
        connection = {
            "id": unique_row_id(connections, f"conn-{name}"),
            "name": name,
            "base_url": url,
            "api_key": str(provider_key or ""),
            "wire_api": str(provider_wire or "chat_completions"),
            "enabled": True,
        }
        connections.append(connection)
    elif provider_key and not str(connection.get("api_key") or "").strip():
        connection["api_key"] = str(provider_key)
    rows = config.setdefault("providers", [])
    for row in rows:
        if (isinstance(row, dict)
                and str(row.get("connection_id")) == str(connection.get("id"))
                and str(row.get("model")) == chosen):
            return row, False
    row = {
        "id": unique_row_id(rows, f"{name}-{chosen}"),
        "name": f"{name} · {chosen}",
        "connection_id": str(connection.get("id")),
        "model": chosen,
        "kind": "anthropic_messages" if str(provider_wire or "") == "anthropic_messages" else "openai_compatible",
        "source": "manual",
        "enabled": True,
    }
    rows.append(row)
    return row, True


def ensure_client_agent(config: dict[str, Any], client: str, agent_id: str = "") -> tuple[dict[str, Any], bool]:
    """每个客户端一个自己的 Agent：没指定就用客户端名（codex / zcode）建一个。"""
    wanted = str(agent_id or "").strip() or client
    agents = config.setdefault("agents", [])
    for item in agents:
        if isinstance(item, dict) and str(item.get("id")) == wanted:
            return item, False
    agent = {
        "id": wanted,
        "name": CLIENT_AGENT_LABELS.get(client, wanted),
        "provider_ids": [],
        "system_prompt": "",
    }
    agents.append(agent)
    return agent, True


def _plan_client_model_write(config: dict[str, Any], *, client: str, path: str,
                             agent_id: str = "", provider_id: str = "", model: str = "",
                             provider_name: str = "", provider_url: str = "",
                             provider_key: str = "", provider_wire: str = "chat_completions") -> dict[str, Any]:
    """只在给定的 config 上算出这次「加模型」要做的事（不写任何文件）。"""
    client = str(client or "").lower().strip()
    # 客户端 id 先过清单：② 里必须有它，而且得是可写的。白名单外的 id 到此为止。
    spec = client_spec(client)
    if spec is None:
        known = [entry["id"] for entry in read_client_registry()]
        raise RuntimeError(
            f"客户端 id「{client}」不在客户端清单（② clients.json）里；清单里的是 {known}。"
            "先把它加进清单再来写，不猜。"
        )
    if not spec["editable"]:
        raise RuntimeError(f"客户端「{spec['id']}」在清单里标着不可写（editable = false）：要写就先在界面上标成可写")
    effective_agent_id = str(agent_id or "").strip() or "default"
    # 客户端类型只选择 Adapter；模型绑定统一落到固定 default Agent。
    validate_write_id(config, effective_agent_id)
    target = Path(os.path.expanduser(path)).resolve()
    if not target.exists():
        raise RuntimeError(f"找不到客户端配置：{target}")
    # 写哪个客户端由文件格式说了算：格式先认，认不出就到此为止，
    # 别等 router.json 都写完才发现客户端文件不能碰。
    writer = writer_for_path(target)
    if writer == "claude" and client != "claude":
        raise RuntimeError(f"{target.name} 是 Claude Code 配置，不是客户端「{client}」：拒绝改别的软件")
    if not str(agent_id or "").strip():
        _warn("没指定客户端 Agent id，按统一 default Agent 处理")
    row, row_created = resolve_supplier_row(config, provider_id, provider_name, provider_url,
                                            provider_key, provider_wire, model)
    chosen = str(model or row.get("model") or "").strip()
    if not chosen:
        raise RuntimeError("这条线路没有模型名：先在供应商池里填好模型再来添加")
    # 模型池里的“加入 4202 分配”仍是独立的 route-only 操作；真正把 Codex
    # 客户端接入 4230 只由 --sync-agent（统一网关确认框）执行。
    if client == "codex":
        assignment_added = assign_client_model(config, client, chosen)
        return {
            "client": client,
            "path": str(target),
            "writer": writer,
            "agent": "codex",
            "agent_created": False,
            "row_id": str(row.get("id") or ""),
            "row_created": row_created,
            "binding_added": assignment_added,
            "assignment_added": assignment_added,
            "model": chosen,
        }
    assignment_added = assign_client_model(config, client, chosen)
    agent, agent_created = ensure_client_agent(config, str(spec["id"]), effective_agent_id)
    bound = agent.setdefault("provider_ids", [])
    binding_added = str(row.get("id")) not in bound
    if binding_added:
        bound.append(str(row.get("id")))
    return {
        "client": client,
        "path": str(target),
        "writer": writer,
        "agent": str(agent.get("id") or ""),
        "agent_created": agent_created,
        "row_id": str(row.get("id") or ""),
        "row_created": row_created,
        "binding_added": binding_added,
        "assignment_added": assignment_added,
        "model": chosen,
    }


def plan_agent_model(config: dict[str, Any] | None = None, **options: Any) -> dict[str, Any]:
    """只预览：把某个模型加到某个客户端会改哪些文件（真实 diff，不写盘）。"""
    import copy
    import difflib
    import tempfile

    global BASE_DIR, CONFIG_PATH

    base = config if config is not None else ensure_config()
    staged = copy.deepcopy(base)
    plan = _plan_client_model_write(staged, **options)
    target = Path(plan["path"])
    original = target.read_text(encoding="utf-8")
    settings = gateway_settings(staged)
    # 预览只展示结构和地址，绝不把现有网关密钥带进确认框。真正写入时
    # `add_model_to_external_agent` 仍会从真实配置读取密钥。
    settings["api_key"] = "sk-gateway-（写入时使用已配置密钥）"
    saved_paths = (BASE_DIR, CONFIG_PATH)
    with tempfile.TemporaryDirectory(prefix="ai-assistant-plan-") as temporary:
        # 预览期间连配置写入都挪进临时目录：真实文件一个字节都不许动。
        BASE_DIR = Path(temporary)
        CONFIG_PATH = BASE_DIR / "router.json"
        try:
            parts = target.parts
            marker = next((item for item in (".codex", ".zcode", ".claude", ".config") if item in parts), None)
            relative = Path(*parts[parts.index(marker):]) if marker else Path(target.name)
            preview_path = Path(temporary) / relative
            preview_path.parent.mkdir(parents=True, exist_ok=True)
            preview_path.write_bytes(target.read_bytes())
            written = sync_external_agent(staged, plan["client"], str(preview_path), plan["agent"],
                                          preferred_model=plan["model"], exact_agent=True,
                                          route_only=plan["client"] == "codex")
            updated = preview_path.read_text(encoding="utf-8")
        finally:
            BASE_DIR, CONFIG_PATH = saved_paths
    diff = [
        line for line in difflib.unified_diff(
            original.splitlines(), updated.splitlines(),
            fromfile=str(target), tofile=str(target), lineterm="", n=2,
        )
    ]
    return {
        "client": plan["client"],
        "client_path": str(target),
        "writer": plan["writer"],
        "agent": plan["agent"],
        "agent_created": plan["agent_created"],
        "row_id": plan["row_id"],
        "row_created": plan["row_created"],
        "binding_added": plan["binding_added"],
        "assignment_added": plan.get("assignment_added", False),
        "model": written["current_model"],
        "models": written["models"],
        "gateway_base_url": written["base_url"],
        "changed": bool(diff),
        "diff": diff,
    }


def add_model_to_external_agent(config: dict[str, Any] | None = None, **options: Any) -> dict[str, Any]:
    """把选中的模型交给某个客户端：绑线路到它的 Agent + 客户端指向网关，一次做完。"""
    base = config if config is not None else ensure_config()
    plan = _plan_client_model_write(base, **options)
    # agent_created 也要落盘：否则新客户端会指向一个配置里根本不存在的 Agent。
    router_backup = None
    if plan["row_created"] or plan["binding_added"] or plan["agent_created"] or plan.get("assignment_added"):
        if CONFIG_PATH.exists():
            router_backup = backup_file(CONFIG_PATH)
        write_config(base)
    written = sync_external_agent(base, plan["client"], plan["path"], plan["agent"],
                                  preferred_model=plan["model"], exact_agent=True,
                                  route_only=plan["client"] == "codex")
    if written["agent"] != plan["agent"]:
        raise RuntimeError(
            f"写出去的是 Agent「{written['agent']}」，和计划的「{plan['agent']}」不一致：停下来，别用这份结果"
        )
    return {
        "client": plan["client"],
        "client_path": plan["path"],
        "writer": written["writer"],
        "agent": plan["agent"],
        "agent_created": plan["agent_created"],
        "row_id": plan["row_id"],
        "row_created": plan["row_created"],
        "binding_added": plan["binding_added"],
        "assignment_added": plan.get("assignment_added", False),
        "model": written["current_model"],
        "models": written["models"],
        "gateway_base_url": written["base_url"],
        "backup": written["backup"],
        "router_backup": router_backup,
    }


def agent_model_write_self_test() -> int:
    """离线验证「加模型」同时改了客户端和 Agent，而且预览阶段绝不动真实文件。"""
    import copy
    import tempfile

    global BASE_DIR, CONFIG_PATH
    saved = (BASE_DIR, CONFIG_PATH)
    with tempfile.TemporaryDirectory(prefix="ai-assistant-agent-model-") as temporary:
        root = Path(temporary)
        BASE_DIR = root
        CONFIG_PATH = root / "router.json"
        codex_path = root / ".codex" / "config.toml"
        zcode_path = root / ".zcode" / "v2" / "config.json"
        opencode_path = root / ".config" / "opencode" / "opencode.json"
        claude_path = root / ".claude" / "settings.json"
        codex_path.parent.mkdir(parents=True)
        zcode_path.parent.mkdir(parents=True)
        opencode_path.parent.mkdir(parents=True)
        claude_path.parent.mkdir(parents=True)
        original_codex = 'model = "omni-chat"\nmodel_provider = "somewhere-else"\n'
        try:
            write_config({
                "version": 1,
                "gateway": {"port": 4230, "agent_id": "default"},
                "connections": [{
                    "id": "conn-9e",
                    "name": "9e",
                    "base_url": "https://api.9e.ai/step",
                    "api_key": "self-test-key",
                    "wire_api": "chat_completions",
                    "enabled": True,
                }],
                "providers": [{
                    "id": "dsh-omni",
                    "name": "DSH · omni-chat",
                    "connection_id": "conn-9e",
                    "model": "omni-chat",
                    "kind": "openai_compatible",
                    "source": "manual",
                    "enabled": True,
                }],
                "agents": [{
                    "id": "default",
                    "name": "默认助手",
                    "provider_ids": ["dsh-omni"],
                    "system_prompt": "",
                }],
            })
            before = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            codex_path.write_text(original_codex, encoding="utf-8")
            preview = plan_agent_model(
                copy.deepcopy(before), client="codex", path=str(codex_path),
                provider_id="dsh-omni", model="omni-chat",
            )
            assert preview["agent"] == "codex", preview
            assert preview["agent_created"] is False, preview
            assert preview["binding_added"] is True, preview
            assert preview["assignment_added"] is True, preview
            assert preview["changed"] is False, preview
            assert json.loads(CONFIG_PATH.read_text(encoding="utf-8")) == before, "预览阶段动了真实配置"
            assert codex_path.read_text(encoding="utf-8") == original_codex, "预览阶段动了客户端文件"

            result = add_model_to_external_agent(
                client="codex", path=str(codex_path), provider_id="dsh-omni", model="omni-chat",
            )
            assert result["agent"] == "codex", result
            assert result["model"] == "omni-chat", result
            written = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            assert written["client_assignments"]["codex"] == ["omni-chat"], written
            assert result["router_backup"] and Path(result["router_backup"]).read_bytes() != CONFIG_PATH.read_bytes()
            text = codex_path.read_text(encoding="utf-8")
            assert text == original_codex, text

            second = add_model_to_external_agent(
                client="codex", path=str(codex_path), provider_id="dsh-omni", model="omni-chat",
            )
            assert second["binding_added"] is False, second
            assert second["assignment_added"] is False, second
            assert second["row_created"] is False, second
            assert json.loads(CONFIG_PATH.read_text(encoding="utf-8")) == written, "重复添加改动了配置"
            again = codex_path.read_text(encoding="utf-8")
            assert again == original_codex, again

            zcode_path.write_text("{}\n", encoding="utf-8")
            add_model_to_external_agent(
                client="zcode", path=str(zcode_path), provider_id="dsh-omni", model="omni-chat",
            )
            payload = json.loads(zcode_path.read_text(encoding="utf-8"))
            block = payload["provider"]["ai-assistant-default"]
            assert block["options"]["baseURL"].endswith("/agents/default/v1"), block
            assert list(block["models"]) == ["omni-chat"], block

            opencode_path.write_text(json.dumps({"$schema": "https://opencode.ai/config.json"}) + "\n", encoding="utf-8")
            codex_before_other_clients = codex_path.read_text(encoding="utf-8")
            assignments_before_other_clients = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["client_assignments"]["codex"][:]
            add_model_to_external_agent(
                client="opencode", path=str(opencode_path), provider_id="dsh-omni", model="omni-chat",
            )
            opencode = json.loads(opencode_path.read_text(encoding="utf-8"))
            opencode_block = opencode["provider"]["ai-assistant-default"]
            assert opencode_block["options"]["baseURL"].endswith("/agents/default/v1"), opencode_block
            assert list(opencode_block["models"]) == ["omni-chat"], opencode_block
            assert codex_path.read_text(encoding="utf-8") == codex_before_other_clients
            assert json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["client_assignments"]["codex"] == assignments_before_other_clients

            claude_path.write_text(json.dumps({"permissions": {"allow": ["Bash"]}}) + "\n", encoding="utf-8")
            add_model_to_external_agent(
                client="claude", path=str(claude_path), provider_id="dsh-omni", model="omni-chat",
            )
            claude = json.loads(claude_path.read_text(encoding="utf-8"))
            assert claude["permissions"] == {"allow": ["Bash"]}, claude
            assert claude["env"]["ANTHROPIC_MODEL"] == "omni-chat", claude
            assert json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["client_assignments"]["opencode"] == ["omni-chat"]
            assert json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["client_assignments"]["claude"] == ["omni-chat"]
        finally:
            BASE_DIR, CONFIG_PATH = saved
    print("agent-model-write self-test: OK")
    return 0


def agents_self_test() -> int:
    """离线验收「三类 id + 写入」：全程只在临时目录里动文件，真实配置一个字节都不碰。

    每项分开报，不堆成一个 assert：一处不过也能一眼看出是哪一项。
    """
    import tempfile

    global BASE_DIR, CONFIG_PATH

    def sample_config() -> dict[str, Any]:
        return {
            "version": 1,
            "gateway": {"host": "127.0.0.1", "port": 4230, "agent_id": "default"},
            "connections": [{
                "id": "conn-9e",
                "name": "9e",
                "base_url": "https://api.9e.ai/step",
                "api_key": "self-test-key",
                "wire_api": "chat_completions",
                "enabled": True,
            }],
            "providers": [{
                "id": "dsh-omni",
                "name": "DSH · omni-chat",
                "connection_id": "conn-9e",
                "model": "omni-chat",
                "kind": "openai_compatible",
                "source": "manual",
                "enabled": True,
            }],
            "agents": [{"id": "default", "name": "默认助手", "provider_ids": ["dsh-omni"], "system_prompt": ""}],
        }

    passed: list[str] = []

    def check(label: str, condition: Any, detail: Any = "") -> None:
        if not condition:
            raise AssertionError(f"{label} —— 实际是：{detail}")
        passed.append(label)

    def expect_error(call: Any, needle: str) -> str:
        try:
            call()
        except RuntimeError as error:
            text = str(error)
            if needle not in text:
                raise AssertionError(f"报错里没有「{needle}」：{text}") from error
            return text
        raise AssertionError(f"本来该报错（要含「{needle}」），却顺利通过了")

    saved_env = (BASE_DIR, CONFIG_PATH)
    saved_detected = globals().get("detected_clients")
    try:
        with tempfile.TemporaryDirectory(prefix="ai-assistant-agents-") as temporary:
            root = Path(temporary)
            BASE_DIR = root
            CONFIG_PATH = root / "router.json"
            codex_path = root / "codex-home" / ".codex" / "config.toml"
            cursor_path = root / "cursor-home" / ".codex" / "config.toml"
            claude_path = root / "claude-home" / ".claude" / "settings.json"
            unknown_path = root / "tool-x" / "config.toml"
            claude_original = json.dumps({"permissions": {"allow": ["Bash"]}}) + "\n"
            codex_path.parent.mkdir(parents=True)
            cursor_path.parent.mkdir(parents=True)
            claude_path.parent.mkdir(parents=True)
            codex_path.write_text('model = "omni-chat"\nmodel_provider = "somewhere-else"\n', encoding="utf-8")
            cursor_path.write_text('model = "gpt-5"\n', encoding="utf-8")
            claude_path.write_text(claude_original, encoding="utf-8")

            codex_row = {"id": "codex", "name": "Codex", "path": str(codex_path), "editable": True}
            cursor_row = {"id": "cursor", "name": "Cursor", "path": str(cursor_path), "editable": True}
            readonly_row = {"id": "claude", "name": "Claude Code", "path": str(claude_path), "editable": False}

            def registry(*rows: dict[str, Any]) -> None:
                (root / "clients.json").write_text(
                    json.dumps([codex_row, *rows], ensure_ascii=False), encoding="utf-8")

            # ③ 用假的扫描结果顶替真扫本机：自检不许依赖这台机器装了什么。
            globals()["detected_clients"] = lambda: {
                str(unknown_path): {
                    "id": "tool-x", "name": "工具X", "path": str(unknown_path),
                    "models": ["x-1"], "current_model": "x-1",
                },
            }
            config = sample_config()
            write_config(config)
            registry(readonly_row)

            check("② 客户端清单在界面里现改现生效：还没加的找不到", client_spec("cursor") is None)
            registry(readonly_row, cursor_row)
            check("新加的客户端，下一次调用就能写",
                  (client_spec("cursor") or {}).get("path") == str(cursor_path))

            listing = export_agents(config)
            kinds: dict[str, list[str]] = {}
            for row in listing["clients"]:
                kinds.setdefault(row["kind"], []).append(row["id"])
            check("导出是只读的：不改调用方手里的配置", config == sample_config(), config)
            check("一张表里 ①②③ 三类都在", sorted(kinds) == ["client", "detected", "router"], kinds)
            check("① 的 Agent 各一行", kinds.get("router") == ["default"], kinds)
            check("② 的客户端各一行", sorted(kinds.get("client") or []) == ["claude", "codex", "cursor"], kinds)
            check("③ 检测到的各一行", kinds.get("detected") == ["tool-x"], kinds)
            check("写入白名单 = ① ∪ ②，③ 不在里面",
                  sorted(listing["whitelist"]["ids"]) == ["claude", "codex", "cursor", "default"],
                  listing["whitelist"])
            check("counts 和表对得上",
                  listing["counts"]["total"] == len(listing["clients"]) == 5, listing["counts"])
            detected_row = [row for row in listing["clients"] if row["kind"] == "detected"][0]
            check("写不了的行会说明原因（只读或同 id 重复）",
                  detected_row["writable"] is False and bool(detected_row["reason"]), detected_row)

            # id 白名单：① 和 ② 都收，陌生 id 直接报错，绝不回落到 default 猜着写。
            check("① 的 Agent id 能写", validate_write_id(config, "default")[0] == "default")
            check("② 的客户端 id 能写", validate_write_id(config, "cursor")[0] == "cursor")
            expect_error(lambda: validate_write_id(config, "cc-unknown"), "白名单")
            fallback_id, note = validate_write_id(config, "", fallback="cursor")
            check("空 id 只提醒一句、不报错", fallback_id == "cursor" and "cursor" in note, note)
            check("宽松版会回落、严格版不会（所以写入路径必须用严格版）",
                  find_agent(config, "cc-typo")["id"] == "default" and find_agent_exact(config, "cc-typo") is None)

            # 预览：真 diff、不写盘；空 Agent id 统一落到固定 default Agent（不再给每个客户端
            # 另建同名 Agent —— 否则 ① 里会一排「cursor/claude/codex」，页面数字全对不上）。
            disk_before_preview = CONFIG_PATH.read_bytes()
            memory_before_preview = json.dumps(config, ensure_ascii=False, sort_keys=True)
            preview = plan_agent_model(config, client="cursor", path=str(cursor_path),
                                       provider_id="dsh-omni", model="omni-chat")
            check("空 Agent id 落到统一的 default Agent，不是客户端自己的 id",
                  preview["agent"] == "default" and preview["agent"] != "cursor"
                  and preview["row_created"] is False, preview)
            check("default 已存在、这条线路也早绑在 default 上：不新建、不重复绑定",
                  preview["agent_created"] is False and preview["binding_added"] is False, preview)
            check("预览里的网关地址就是 default 那一份",
                  preview["gateway_base_url"] == "http://127.0.0.1:4230/agents/default/v1", preview)
            check("预览按文件格式挑写入器", preview["writer"] == "codex", preview)
            # default 上还没绑这条线路时，预览必须显示「要新增绑定」——统一 default 也要真绑得上。
            unbound = sample_config()
            unbound["agents"][0]["provider_ids"] = []
            unbound_preview = plan_agent_model(unbound, client="cursor", path=str(cursor_path),
                                               provider_id="dsh-omni", model="omni-chat")
            check("default 没绑过：预览显示要新增绑定",
                  unbound_preview["agent"] == "default" and unbound_preview["agent_created"] is False
                  and unbound_preview["binding_added"] is True, unbound_preview)
            check("预览不改调用方递进来的配置对象",
                  unbound["agents"][0]["provider_ids"] == [], unbound)
            check("预览阶段客户端文件没动", cursor_path.read_text(encoding="utf-8") == 'model = "gpt-5"\n')
            check("预览阶段 router.json 一个字节都没动", CONFIG_PATH.read_bytes() == disk_before_preview)
            check("预览也不改内存里的配置（不然界面会显示成已生效）",
                  json.dumps(config, ensure_ascii=False, sort_keys=True) == memory_before_preview)

            # 真写盘：客户端文件里只许有网关地址，上游地址和 Key 一个都不许落进去。
            before_cursor = cursor_path.read_bytes()
            before_config = CONFIG_PATH.read_bytes()
            applied = add_model_to_external_agent(config, client="cursor", path=str(cursor_path),
                                                  provider_id="dsh-omni", model="omni-chat")
            check("写的是统一的 default Agent（不给客户端另建 Agent）",
                  applied["agent"] == "default", applied)
            text = cursor_path.read_text(encoding="utf-8")
            check("客户端文件里只有网关地址，没有上游地址/Key",
                  "/agents/default/v1" in text and "9e.ai" not in text and "self-test-key" not in text, text)
            check("写前先备份，备份就是原文",
                  Path(applied["backup"]).read_bytes() == before_cursor, applied["backup"])
            check("没新建 Agent、没新增绑定（default 早绑好了），也没复制线路",
                  applied["agent_created"] is False and applied["binding_added"] is False
                  and applied["row_created"] is False, applied)
            stored = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            check("router.json 里只有 default 一个 Agent，绑定还是那一条（没多出 cursor 专属 Agent）",
                  [item["id"] for item in stored["agents"]] == ["default"]
                  and stored["agents"][0]["provider_ids"] == ["dsh-omni"], stored["agents"])
            check("供应商池里没多出第二份配置", len(stored["providers"]) == 1, stored["providers"])
            check("配置确实落盘了", CONFIG_PATH.read_bytes() != before_config)

            merged = [row for row in export_agents(stored)["clients"] if row["id"] == "cursor"][0]
            check("写完再导出：② 那一行没有专属 router Agent 可合并（ids.router 是空的）",
                  merged["kind"] == "client" and merged["ids"]["router"] == ""
                  and merged["ids"]["client"] == "cursor", merged)
            check("导出件里不带 API Key（上游密钥不外流）",
                  "self-test-key" not in json.dumps(export_agents(stored), ensure_ascii=False))

            # 显式点名 agent_id：这是用户自己要求的 id，仍然照建（默认路径才走统一的 default）。
            # 单独拿一份干净副本，免得两张表混进来，把上面「只有一张表」的结论搅浑。
            explicit_path = root / "cursor-explicit-home" / ".codex" / "config.toml"
            explicit_path.parent.mkdir(parents=True)
            explicit_path.write_text('model = "gpt-5"\n', encoding="utf-8")
            again = add_model_to_external_agent(
                json.loads(CONFIG_PATH.read_text(encoding="utf-8")), client="cursor",
                path=str(explicit_path), agent_id="cursor", provider_id="dsh-omni", model="omni-chat")
            check("显式指定 id 时才建对应 Agent，且绑定按需加上",
                  again["agent"] == "cursor" and again["agent_created"] is True
                  and again["binding_added"] is True and again["row_created"] is False, again)
            check("显式指定也不动 default 的绑定",
                  json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["agents"][0]["provider_ids"] == ["dsh-omni"])
            check("显式指定那一份文件里只有 cursor 那一张表，default 那套没跟着漏过去",
                  explicit_path.read_text(encoding="utf-8").count("[model_providers.") == 1
                  and "/agents/cursor/v1" in explicit_path.read_text(encoding="utf-8"),
                  explicit_path.read_text(encoding="utf-8"))
            merged_explicit = [row for row in export_agents(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))["clients"]
                               if row["id"] == "cursor"][0]
            check("显式建了 Agent 之后，② 那一行才和它合成一行",
                  merged_explicit["ids"]["router"] == "cursor", merged_explicit)
            third = add_model_to_external_agent(
                json.loads(CONFIG_PATH.read_text(encoding="utf-8")), client="cursor",
                path=str(explicit_path), agent_id="cursor", provider_id="dsh-omni", model="omni-chat")
            check("再点一次：不叠表、不重复绑定",
                  third["agent_created"] is False and third["binding_added"] is False, third)
            check("再点一次也没多出表",
                  explicit_path.read_text(encoding="utf-8").count("[model_providers.") == 1)
            check("正确路径写的那一份，从头到尾只有一张 provider 表（cursor 那份没被碰）",
                  cursor_path.read_text(encoding="utf-8").count("[model_providers.") == 1)
            check("第二次也没有复制线路",
                  len(json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["providers"]) == 1)
            text = cursor_path.read_text(encoding="utf-8")
            # 上面显式建 Agent 那一步确实写过盘了：后面比「没变」的基准要重新取。
            stored = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))

            # 写错 Agent id：报错 + 两个文件都不许动（尤其是别落到 default 上）。
            expect_error(lambda: sync_external_agent(
                json.loads(CONFIG_PATH.read_text(encoding="utf-8")),
                "cursor", str(cursor_path), "cc-typo", exact_agent=True), "拒绝改写")
            check("写错 id 时客户端文件一个字节没变", cursor_path.read_text(encoding="utf-8") == text)
            check("写错 id 时 router.json 也没变",
                  json.loads(CONFIG_PATH.read_text(encoding="utf-8")) == stored)

            # 只读的客户端、认不出的文件格式：都必须「先拒绝、后写盘」。
            expect_error(lambda: add_model_to_external_agent(
                stored, client="claude", path=str(claude_path),
                agent_id="claude", provider_id="dsh-omni", model="omni-chat"), "不可写")
            check("不可写的客户端文件没被动过", claude_path.read_text(encoding="utf-8") == claude_original)
            registry(readonly_row, cursor_row,
                     {"id": "mysettings", "name": "别的工具", "path": str(claude_path), "editable": True})
            error = expect_error(lambda: add_model_to_external_agent(
                json.loads(CONFIG_PATH.read_text(encoding="utf-8")), client="mysettings",
                path=str(claude_path), provider_id="dsh-omni", model="omni-chat"), "别的软件")
            check("认不出的配置：报错里带文件名", claude_path.name in error, error)
            check("认不出就不写：router.json 没被先改一步",
                  json.loads(CONFIG_PATH.read_text(encoding="utf-8")) == stored)
            check("认不出的文件一个字节没动", claude_path.read_text(encoding="utf-8") == claude_original)

            # 界面删掉客户端：② 白名单立刻收紧，但 ① 里已有的 Agent 不会被一起抹掉。
            registry(readonly_row)
            check("删掉之后 ② 里立刻没有它", client_spec("cursor") is None)
            expect_error(lambda: add_model_to_external_agent(
                json.loads(CONFIG_PATH.read_text(encoding="utf-8")), client="cursor",
                path=str(cursor_path), agent_id="cursor", provider_id="dsh-omni",
                model="omni-chat"), "不在客户端清单")
            check("删客户端不动 ① 的 Agent",
                  any(item["id"] == "cursor"
                      for item in json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["agents"]))

            # 真地址那一张表：拿连接里的 Base URL，不许拿连接名/供应商名充数。
            fresh = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            rows = agent_model_rows(fresh)
            check("每个 Agent 的每条线路一行", len(rows) == 2, rows)
            check("每行都带真地址（连接里那条）",
                  all(row["base_url"] == "https://api.9e.ai/step" for row in rows), rows)
            check("每行模型名齐全、不算错",
                  all(row["model"] == "omni-chat" and not row["error"] for row in rows), rows)
            check("能只看一个 Agent",
                  {row["agent_id"] for row in agent_model_rows(fresh, "cursor")} == {"cursor"})
            expect_error(lambda: agent_model_rows(fresh, "cc-typo"), "没有 Agent")
            broken = sample_config()
            broken["connections"].append({"id": "conn-empty", "name": "空地址", "base_url": "", "enabled": True})
            broken["providers"].append({"id": "row-empty", "name": "空地址线路", "connection_id": "conn-empty",
                                        "model": "m-1", "enabled": True})
            broken["agents"][0]["provider_ids"] = ["dsh-omni", "row-empty"]
            check("地址为空就那一行报错，不拿连接名糊弄",
                  [row["error"] for row in agent_model_rows(broken, "default")]
                  == ["", "线路没配地址：去模型池把 Base URL 补上"],
                  agent_model_rows(broken, "default"))
    finally:
        BASE_DIR, CONFIG_PATH = saved_env
        if saved_detected is None:
            globals().pop("detected_clients", None)
        else:
            globals()["detected_clients"] = saved_detected
    print(f"agents self-test passed（{len(passed)} 项）")
    for label in passed:
        print(f"  ✓ {label}")
    return 0


def resolve_secret(value: Any) -> str:
    text = str(value or "")
    if text.startswith("${") and text.endswith("}"):
        return os.environ.get(text[2:-1], "")
    if text.startswith("$") and len(text) > 1:
        return os.environ.get(text[1:], "")
    return text


def resolve_api_key(provider: dict[str, Any]) -> str:
    """API Key 来源：api_key_file > 已设置的环境变量 > 配置里的字面量。

    api_key_env 只在环境变量**真的存在**时才生效：GUI 从 ~/.dsh 导入时会同时
    写入 api_key_env 和字面量 Key，而 App 从 Finder 启动时没有这些环境变量，
    旧逻辑优先读环境变量会让中转站在毫无提示的情况下 401。
    """
    key_file = str(provider.get("api_key_file") or "").strip()
    if key_file:
        try:
            with open(os.path.expanduser(key_file), encoding="utf-8") as handle:
                return handle.read().strip()
        except OSError as exc:
            raise RuntimeError(f"无法读取 API Key 文件：{exc}") from exc
    environment_name = str(provider.get("api_key_env") or "").strip()
    if environment_name:
        from_environment = os.environ.get(environment_name, "").strip()
        if from_environment:
            return from_environment
    return resolve_secret(provider.get("api_key"))


def is_responses_wire(provider: dict[str, Any]) -> bool:
    wire = str(provider.get("wire_api") or "chat_completions").strip().lower()
    return wire in {"responses", "openai-responses", "openai_responses", "response"}


def is_anthropic_wire(provider: dict[str, Any]) -> bool:
    """Chat Completions / Responses 之外的第三种线：Claude 的 /v1/messages。"""
    wire = str(provider.get("wire_api") or "").strip().lower()
    return wire in {"anthropic", "anthropic_messages", "anthropic-messages", "messages"}


def normalize_wire(value: Any) -> str:
    """把各家配置里的写法收敛成三种线之一。"""
    text = str(value or "").strip().lower()
    if text in {"responses", "openai-responses", "openai_responses", "response"}:
        return "responses"
    if text in {"anthropic", "anthropic_messages", "anthropic-messages", "messages", "claude"}:
        return "anthropic_messages"
    return "chat_completions"


def extract_anthropic_text(payload: dict[str, Any]) -> str:
    chunks: list[str] = []
    for part in payload.get("content") or []:
        if isinstance(part, dict) and isinstance(part.get("text"), str):
            chunks.append(part["text"])
    return "".join(chunks).strip()


def extract_responses_text(payload: dict[str, Any]) -> str:
    direct = payload.get("output_text")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    chunks: list[str] = []
    for item in payload.get("output") or []:
        if not isinstance(item, dict):
            continue
        # DeepSeek 的 reasoning item 也带 content（reasoning_text），不能把
        # 思考拼进正文，否则语音/纯文本链路会读出「We need answer...」前导语。
        if item.get("type") == "reasoning":
            continue
        for part in item.get("content") or []:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                chunks.append(part["text"])
    return "".join(chunks).strip()


def responses_input(prompt: str) -> list[dict[str, Any]]:
    """Responses 线要求 input 是数组：纯字符串会被部分中转站直接 400 拒绝。"""
    return [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": prompt}],
        }
    ]


def read_stream_text(response: Any) -> str:
    """读取 SSE 流：同时兼容 Responses 事件和 chat/completions 增量。"""
    chunks: list[str] = []
    completed: dict[str, Any] | None = None
    for raw in response:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            event = json.loads(data)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        kind = str(event.get("type") or "")
        if kind.endswith("output_text.delta"):
            delta = event.get("delta")
            if isinstance(delta, str):
                chunks.append(delta)
        elif kind in {"content_block_delta", "content_block_start"}:
            # Anthropic /v1/messages 的增量：text 藏在 delta.text 或 content_block.text。
            block = event.get("delta") or event.get("content_block") or {}
            text = block.get("text") if isinstance(block, dict) else None
            if isinstance(text, str):
                chunks.append(text)
        elif kind == "message_start":
            # message_start 里通常 content 是空的，个别中转站会塞整段回答。
            message = event.get("message")
            if isinstance(message, dict):
                text = extract_anthropic_text(message)
                if text:
                    chunks.append(text)
        elif kind == "response.completed":
            payload = event.get("response")
            if isinstance(payload, dict):
                completed = payload
        else:
            for choice in event.get("choices") or []:
                if not isinstance(choice, dict):
                    continue
                delta = (choice.get("delta") or {}).get("content")
                if isinstance(delta, str):
                    chunks.append(delta)
    text = "".join(chunks).strip()
    if not text and completed:
        text = extract_responses_text(completed)
    return text


def run_command(provider: dict[str, Any], prompt: str) -> str:
    executable = str(provider.get("executable") or "")
    if not executable or not os.path.isfile(executable) or not os.access(executable, os.X_OK):
        raise RuntimeError(f"{provider.get('name', '命令供应商')} 不可用：{executable}")
    arguments = [str(item) for item in (provider.get("arguments") or [])]
    timeout = float(provider.get("timeout_seconds") or DEFAULT_TIMEOUT)
    process = subprocess.Popen(
        [executable, *arguments],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        output, error = process.communicate(input=prompt, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise RuntimeError(f"{provider.get('name', '命令供应商')} 超时")
    output = (output or "").strip()
    error = (error or "").strip()
    combined = f"{output}\n{error}".lower()
    if process.returncode != 0 or not output:
        raise RuntimeError(error or f"退出码 {process.returncode}")
    if any(marker in combined for marker in QUOTA_MARKERS):
        raise RuntimeError(error or output[:500])
    return output


def run_dsh_bridge(provider: dict[str, Any], prompt: str) -> str:
    bridge_dir = Path(
        os.path.expanduser(
            str(
                provider.get(
                    "bridge_dir",
                    "~/Library/Application Support/LocalSiriLLM/dsh-bridge",
                )
            )
        )
    )
    request_path = bridge_dir / "request.json"
    response_path = bridge_dir / "response.json"
    timeout = float(provider.get("timeout_seconds") or DEFAULT_TIMEOUT)
    bridge_dir.mkdir(parents=True, exist_ok=True)
    request_id = uuid.uuid4().hex
    try:
        response_path.unlink()
    except FileNotFoundError:
        pass
    temporary = request_path.with_suffix(".json.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump({"id": request_id, "prompt": prompt}, handle, ensure_ascii=False)
    os.replace(temporary, request_path)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with response_path.open(encoding="utf-8") as handle:
                payload = json.load(handle)
        except (FileNotFoundError, json.JSONDecodeError):
            payload = None
        if isinstance(payload, dict) and payload.get("id") == request_id:
            answer = str(payload.get("answer") or "").strip()
            if answer:
                return answer
            raise RuntimeError(str(payload.get("error") or "DSH 返回空回答"))
        time.sleep(0.15)
    raise RuntimeError("DSH 桥超时（请确认 DSH 客户端正在运行）")


def run_openai_compatible(provider: dict[str, Any], prompt: str) -> str:
    base_url = str(provider.get("base_url") or "").rstrip("/")
    if not base_url:
        raise RuntimeError("缺少中转站 Base URL")
    model = str(provider.get("model") or "")
    if not model:
        raise RuntimeError("缺少模型名")
    system_prompt = str(provider.get("system_prompt") or "").strip()
    # 少数中转站（例如本地 Codex Router 代理）强制要求 SSE，不接受一次性 JSON。
    stream = bool(provider.get("stream"))
    if is_anthropic_wire(provider):
        if not base_url.endswith("/messages"):
            base_url += "/messages"
        body: dict[str, Any] = {
            "model": model,
            "max_tokens": int(provider.get("max_tokens") or 8192),
            "messages": [{"role": "user", "content": prompt}],
            "stream": stream,
        }
        if system_prompt:
            body["system"] = system_prompt
    elif is_responses_wire(provider):
        if not base_url.endswith("/responses"):
            base_url += "/responses"
        body: dict[str, Any] = {
            "model": model,
            "input": responses_input(prompt),
            "stream": stream,
        }
        if system_prompt:
            body["instructions"] = system_prompt
    else:
        if not base_url.endswith("/chat/completions"):
            base_url += "/chat/completions"
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        body = {
            "model": model,
            "messages": messages,
            "temperature": provider.get("temperature", 0.2),
            "stream": stream,
        }
    headers = {"Content-Type": "application/json"}
    api_key = resolve_api_key(provider)
    if api_key:
        if is_anthropic_wire(provider):
            # Claude 官方线用 x-api-key，不是 Bearer。
            headers["x-api-key"] = api_key
            headers["anthropic-version"] = str(
                provider.get("anthropic_version") or "2023-06-01"
            )
        else:
            headers["Authorization"] = f"Bearer {api_key}"
    for key, value in (provider.get("headers") or {}).items():
        headers[str(key)] = str(value)
    request = urllib.request.Request(
        base_url,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    timeout = float(provider.get("timeout_seconds") or DEFAULT_TIMEOUT)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if stream:
                answer = read_stream_text(response)
                if not answer:
                    raise RuntimeError("中转站流式返回空回答")
                return answer
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:800]
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"网络错误：{exc.reason}") from exc
    try:
        payload = json.loads(raw)
    except ValueError as exc:
        # 很多中转站/直连域名前面挂着 WAF（阿里云 acw_tc、Cloudflare 等），
        # 非浏览器流量会收到 200 + HTML 挑战页。裸 json 报错没有任何可操作性，
        # 这里明确说清楚，并且让上层 failover 继续试下一条线路。
        head = " ".join(raw[:200].split())
        hint = ""
        lowered = raw[:2000].lower()
        if any(marker in lowered for marker in ("aliyun_waf", "acw_tc", "_waf", "cf-chl", "cloudflare", "challenge")):
            hint = "（疑似被 WAF 拦截：该线路要求浏览器环境，纯 API 客户端无法通过）"
        raise RuntimeError(
            f"返回的不是 JSON{hint}：{head or '<空响应>'}"
        ) from exc
    if is_anthropic_wire(provider):
        answer = extract_anthropic_text(payload)
        if not answer:
            error = payload.get("error")
            detail = error.get("message") if isinstance(error, dict) else error
            raise RuntimeError(str(detail or "中转站没有返回 content"))
    elif is_responses_wire(provider):
        answer = extract_responses_text(payload)
        if not answer:
            answer = str(payload.get("error") or "").strip()
    else:
        choices = payload.get("choices") or []
        if not choices:
            raise RuntimeError(str(payload.get("error") or "中转站没有返回 choices"))
        content = (choices[0].get("message") or {}).get("content")
        if isinstance(content, list):
            content = "".join(
                str(part.get("text") or "")
                for part in content
                if isinstance(part, dict)
            )
        answer = str(content or "").strip()
    if not answer:
        raise RuntimeError("中转站返回空回答")
    return answer


def slugify(value: str) -> str:
    cleaned = []
    for character in value.strip().lower():
        if character.isalnum() and character.isascii():
            cleaned.append(character)
        elif cleaned and cleaned[-1] != "-":
            cleaned.append("-")
    slug = "".join(cleaned).strip("-")
    return slug or "provider"


def mask_url(value: Any) -> str:
    """隐藏本地路由 URL 里的安装令牌（/i_xxx/）。"""
    import re

    return re.sub(r"i_[A-Za-z0-9_-]{8,}", "i_***", str(value or ""))


def import_dsh_config(config: dict[str, Any], dry_run: bool = False) -> list[str]:
    """把 DSH（~/.dsh）里配置的线路 + 模型导入 router.json，每个模型一条供应商。"""
    import yaml

    if not DSH_SETTINGS_PATH.exists():
        raise RuntimeError(f"没有找到 DSH 配置：{DSH_SETTINGS_PATH}")
    with DSH_SETTINGS_PATH.open(encoding="utf-8") as handle:
        settings = yaml.safe_load(handle) or {}
    dsh_providers = ((settings.get("llm-pi-ai") or {}).get("providers")) or {}
    if not isinstance(dsh_providers, dict) or not dsh_providers:
        raise RuntimeError("DSH 配置里没有 llm-pi-ai.providers")

    credentials: dict[str, Any] = {}
    if DSH_CREDENTIALS_PATH.exists():
        try:
            with DSH_CREDENTIALS_PATH.open(encoding="utf-8") as handle:
                credentials = (yaml.safe_load(handle) or {}).get("refs") or {}
        except OSError:
            credentials = {}

    existing_ids = {
        str(provider.get("id"))
        for provider in config.get("providers", [])
        if isinstance(provider, dict)
    }
    added: list[str] = []
    for dsh_id, entry in dsh_providers.items():
        if not isinstance(entry, dict):
            continue
        api = str(entry.get("api") or "openai-completions")
        wire_api, kind = DSH_WIRE_API.get(api, ("chat_completions", "openai_compatible"))
        base_url = str(entry.get("baseURL") or "")
        display = str(entry.get("displayName") or dsh_id)
        key_env = str(entry.get("apiKeyEnv") or "")
        secret = credentials.get(key_env)
        for model in entry.get("models") or []:
            if not isinstance(model, dict):
                continue
            model_id = str(model.get("id") or "").strip()
            if not model_id:
                continue
            label = str(model.get("name") or model_id)
            provider_id = f"{slugify(dsh_id)}-{slugify(model_id)}"
            if provider_id in existing_ids:
                continue
            provider: dict[str, Any] = {
                "id": provider_id,
                "name": f"{display} · {label}",
                "kind": kind,
                "enabled": True,
                "source": f"dsh:{dsh_id}",
                "base_url": base_url,
                "model": model_id,
                "wire_api": wire_api,
                "api_key_env": key_env,
                "timeout_seconds": 120,
            }
            if secret:
                provider["api_key"] = str(secret)
            if not dry_run:
                config.setdefault("providers", []).append(provider)
            existing_ids.add(provider_id)
            key_state = "已带 Key" if secret else f"缺少 {key_env or 'API Key'}"
            added.append(f"{provider_id}  ←  {base_url}  [{wire_api}]  ({key_state})")
    if not dry_run and added:
        write_config(config)
    return added


def parse_toml_fragment(text: str) -> dict[str, dict[str, str]]:
    """够用的 TOML 片段解析：只认 [section] 与 key = value 两类标量。

    Python 3.9 没有 tomllib，而这里真正需要的只有 model / base_url /
    wire_api / env_key 这几个值，为它引第三方库不值得。
    """
    sections: dict[str, dict[str, str]] = {"": {}}
    current = ""
    for raw_line in str(text or "").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip().strip('"')
            sections.setdefault(current, {})
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().rstrip(",").strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        sections.setdefault(current, {})[key.strip().strip('"')] = value
    return sections


# 重新导入时允许自动补齐的字段（Key 单独处理：只补空、不覆盖已有的）。
IMPORT_MERGE_FIELDS = ("base_url", "model", "wire_api", "api_key_env")


def normalized_url(value: Any) -> str:
    return str(value or "").strip().rstrip("/").lower()


def find_provider_by_url(config: dict[str, Any], url: str) -> dict[str, Any] | None:
    target = normalized_url(url)
    if not target:
        return None
    for item in config.get("providers") or []:
        if isinstance(item, dict) and normalized_url(item.get("base_url")) == target:
            return item
    return None


def next_provider_id(config: dict[str, Any], base: str) -> str:
    taken = {
        str(item.get("id"))
        for item in config.get("providers") or []
        if isinstance(item, dict)
    }
    candidate = slugify(base)
    if candidate not in taken:
        return candidate
    counter = 2
    while f"{candidate}-{counter}" in taken:
        counter += 1
    return f"{candidate}-{counter}"


def describe_provider(provider: dict[str, Any]) -> str:
    key_state = "已带 Key" if str(provider.get("api_key") or "").strip() else "缺 Key"
    return (
        f"{provider.get('id')}  ←  {provider.get('base_url')}"
        f"  [{provider.get('wire_api')}]  {provider.get('model') or '(未指定模型)'}  ({key_state})"
    )


def merge_imported_provider(
    config: dict[str, Any],
    provider: dict[str, Any],
    added: list[str],
    updated: list[str],
    skipped: list[str],
) -> None:
    """按地址合并：同一个 base_url 视为同一条线路，绝不重复导入。

    已有的字段一律保留（GUI 手改的值优先），只补空缺；Key 只补空，
    来源不同则记一条提示，让用户自己决定用哪个。
    """
    existing = find_provider_by_url(config, provider.get("base_url"))
    if existing is None:
        config.setdefault("providers", []).append(provider)
        added.append(describe_provider(provider))
        return
    changes: list[str] = []
    for field in IMPORT_MERGE_FIELDS:
        incoming = str(provider.get(field) or "").strip()
        current = str(existing.get(field) or "").strip()
        if not incoming or current:
            continue
        existing[field] = provider[field]
        changes.append(field)
    for extra_key in ("source", "source_name"):
        if provider.get(extra_key) and not existing.get(extra_key):
            existing[extra_key] = provider[extra_key]
    incoming_key = str(provider.get("api_key") or "")
    current_key = str(existing.get("api_key") or "")
    if incoming_key and not current_key:
        existing["api_key"] = incoming_key
        changes.append("api_key")
    elif incoming_key and current_key and incoming_key != current_key:
        skipped.append(
            f"{existing.get('id')}：Key 与来源不同（保留 router.json 里现有的，来源 {provider.get('source')}）"
        )
    if changes:
        updated.append(f"{existing.get('id')}  ←  补齐 {', '.join(changes)}")


def import_codex_config(
    config: dict[str, Any],
    config_path: Path | None = None,
    dry_run: bool = False,
) -> tuple[list[str], list[str], list[str]]:
    """导入 ~/.codex/config.toml 里手写的 [model_providers.*]（本地环回地址跳过）。"""
    added: list[str] = []
    updated: list[str] = []
    skipped: list[str] = []
    path = Path(config_path or CODEX_CONFIG_PATH)
    if not path.exists():
        skipped.append(f"没找到 {path}")
        return added, updated, skipped
    try:
        sections = parse_toml_fragment(path.read_text(encoding="utf-8"))
    except OSError as exc:
        skipped.append(f"读不了 {path}：{exc}")
        return added, updated, skipped
    default_model = str(sections.get("", {}).get("model") or "").strip()
    for name, values in sections.items():
        if not name.startswith("model_providers."):
            continue
        provider_name = name.split(".", 1)[1]
        label = str(values.get("name") or provider_name).strip() or provider_name
        base_url = str(values.get("base_url") or "").strip()
        if not base_url:
            skipped.append(f"Codex · {label}：没有 base_url")
            continue
        lowered = base_url.lower()
        if "127.0.0.1" in lowered or "localhost" in lowered:
            skipped.append(f"Codex · {label}：本地环回地址（本地线路已由 DSH/Codex Router 导入）")
            continue
        if "api.openai.com" in lowered:
            skipped.append(f"Codex · {label}：OpenAI 官方地址（用订阅登录，不是中转站）")
            continue
        env_key = str(values.get("env_key") or "").strip()
        secret = os.environ.get(env_key, "").strip() if env_key else ""
        provider: dict[str, Any] = {
            "id": next_provider_id(config, f"codex-{provider_name}"),
            "name": f"Codex · {label}",
            "kind": "openai_compatible",
            "enabled": True,
            "source": f"codex-config:{provider_name}",
            "source_name": label,
            "base_url": base_url,
            "model": default_model,
            "wire_api": normalize_wire(values.get("wire_api")),
            "timeout_seconds": 120,
        }
        if env_key:
            provider["api_key_env"] = env_key
        if secret:
            provider["api_key"] = secret
        merge_imported_provider(config, provider, added, updated, skipped)
    if not dry_run and (added or updated):
        write_config(config)
    return added, updated, skipped


def run_provider(provider: dict[str, Any], prompt: str) -> str:
    kind = str(provider.get("kind") or "").lower()
    if kind == "dsh_bridge":
        return run_dsh_bridge(provider, prompt)
    if kind == "command":
        return run_command(provider, prompt)
    if kind in {"openai_compatible", "openai-compatible", "http"}:
        return run_openai_compatible(provider, prompt)
    raise RuntimeError(f"不支持的供应商类型：{kind}")


# ---------------------------------------------------------------------------
# 总路由网关：所有 Agent（Codex / Claude Code / 其它客户端）都指向同一个本地地址
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 总路由网关：所有 Agent（Codex / Claude Code / 其它客户端）都指向同一个本地地址
# ---------------------------------------------------------------------------


def attach_providers_to_agent(
    config: dict[str, Any], agent_target: str, provider_ids: list[str]
) -> list[str]:
    """把刚导入的线路挂到一个 Agent 上；Agent 不存在就按这个名字建一个。"""
    target = str(agent_target or "").strip()
    if not target:
        return []
    agents = config.setdefault("agents", [])
    # 注意：不能直接用 find_agent —— 它找不到时会静默回落到 default，
    # 那会把新线路挂到默认助手上，跟"给这个 Agent 导入"是两回事。
    wanted = target.strip().lower()
    agent = None
    for item in agents:
        if not isinstance(item, dict):
            continue
        if str(item.get("id") or "") == target or str(item.get("name") or "").strip().lower() == wanted:
            agent = item
            break
    if agent is None:
        agent = {
            "id": slugify(target),
            "name": target,
            "provider_ids": [],
            "system_prompt": "",
        }
        agents.append(agent)
    current = agent.setdefault("provider_ids", [])
    assigned = []
    for identifier in provider_ids:
        if identifier and identifier not in current:
            current.append(identifier)
            assigned.append(identifier)
    write_config(config)
    return assigned


def gateway_settings(config: dict[str, Any]) -> dict[str, Any]:
    settings = config.get("gateway")
    if not isinstance(settings, dict):
        settings = {}
        config["gateway"] = settings
    settings.setdefault("enabled", True)
    settings.setdefault("host", GATEWAY_DEFAULT_HOST)
    settings.setdefault("port", GATEWAY_DEFAULT_PORT)
    settings.setdefault("agent_id", "omni")
    settings.setdefault("api_key", "")
    return settings


# `--serve` 的临时覆盖（--host / --port / --agent-id）：只活在这个进程里，绝不写回 router.json。
# 网关进程之外它永远是空的，所以「预览 / 查询」类调用读到的一定是盘上的真实配置。
GATEWAY_OVERRIDES: dict[str, Any] = {}


def gateway_view() -> dict[str, Any]:
    """网关进程内读配置：把 `--serve` 的临时覆盖叠上去（内存里，不落盘）。

    网关的 /health 和 /v1/models 都走这里，保证「报出来的地址」就是「真在听的地址」——
    否则 --port 换了监听口却报旧端口，外层的端口闸门就会被骗过。
    """
    config = ensure_config()
    if GATEWAY_OVERRIDES:
        gateway_settings(config).update(GATEWAY_OVERRIDES)
    return config


def ensure_gateway_key(config: dict[str, Any] | None = None) -> str:
    payload = config if config is not None else ensure_config()
    settings = gateway_settings(payload)
    key = str(settings.get("api_key") or "").strip()
    if not key:
        key = f"sk-gateway-{uuid.uuid4().hex[:32]}"
        settings["api_key"] = key
        write_config(payload)
    return key


def gateway_routes(
    config: dict[str, Any], requested: str | None = None
) -> tuple[str, list[dict[str, Any]]]:
    settings = gateway_settings(config)
    target = str(requested or settings.get("agent_id") or "omni").strip() or "omni"
    agent_id = resolve_agent_id(config, target)
    if agent_id not in agent_ids(config):
        # resolve_agent_id 找不到 Agent 时会原样返回请求值，这里落回真实存在的那个，
        # 免得 /health 报一个其实不存在的 Agent 名字。
        agent_id = str(find_agent(config, agent_id).get("id") or "default")
    return agent_id, providers_for_agent(config, agent_id)


def gateway_info(config: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = config if config is not None else ensure_config()
    settings = gateway_settings(payload)
    key = ensure_gateway_key(payload)
    host = str(settings.get("host") or GATEWAY_DEFAULT_HOST)
    port = int(settings.get("port") or GATEWAY_DEFAULT_PORT)
    agent_id = str(settings.get("agent_id") or "omni")
    base_url = f"http://{host}:{port}/v1"
    try:
        routed_agent, routed = gateway_routes(payload, agent_id)
    except Exception:
        routed_agent, routed = agent_id, []
    first_model = ""
    for provider in routed:
        if str(provider.get("model") or "").strip():
            first_model = str(provider["model"]).strip()
            break
    return {
        "enabled": bool(settings.get("enabled", True)),
        "host": host,
        "port": port,
        "base_url": base_url,
        "api_key": key,
        "agent_id": agent_id,
        "resolved_agent": routed_agent,
        "agents": agent_ids(payload),
        "providers": [
            {"id": item.get("id"), "name": item.get("name")}
            for item in routed
        ],
        "config": str(CONFIG_PATH),
        "codex_snippet": "\n".join(
            [
                f'[model_providers.unified]',
                f'name = "统一路由"',
                f'base_url = "{base_url}"',
                f'requires_openai_auth = true',
                f'wire_api = "responses"',
                f'env_key = "UNIFIED_ROUTER_KEY"',
            ]
        ),
        "claude_snippet": "\n".join(
            [
                f'export ANTHROPIC_BASE_URL="{base_url}"',
                f'export ANTHROPIC_AUTH_TOKEN="{key}"',
            ]
        ),
    }


def content_text(content: Any) -> str:
    """一段 message.content 可能是字符串，也可能是 [{"type":"input_text",...}] 这种分片。"""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict):
                text = content_text(part.get("text") or part.get("content") or "")
            else:
                text = str(part).strip()
            if text:
                parts.append(text)
        return "\n".join(parts).strip()
    if content is None:
        return ""
    return str(content).strip()


def gateway_prompt(body: dict[str, Any]) -> str:
    """把 Chat Completions / Responses / Messages 三种入参都还原成一段提示词。"""
    messages = body.get("messages")
    if isinstance(messages, list) and messages:
        chunks = []
        for item in messages:
            if not isinstance(item, dict):
                continue
            text = content_text(item.get("content"))
            if text:
                chunks.append(text)
        if chunks:
            return "\n\n".join(chunks)
    for field in ("input", "prompt", "query"):
        value = body.get(field)
        text = content_text(value)
        if text:
            return text
    instructions = content_text(body.get("instructions"))
    if instructions:
        return instructions
    return ""


def run_chain(
    providers: list[dict[str, Any]],
    prompt: str,
    budget: float = DEFAULT_BUDGET,
) -> tuple[str, list[dict[str, Any]], list[str]]:
    """按 Agent 里的顺序依次尝试，返回（回答, 成功的供应商, 失败原因）。"""
    deadline = time.time() + max(budget, 1.0)
    used: list[dict[str, Any]] = []
    errors: list[str] = []
    skipped_quota = 0
    for index, provider in enumerate(providers, start=1):
        if time.time() > deadline:
            errors.append(f"总预算 {budget:.0f}s 用完，跳过剩 {len(providers) - index + 1} 条")
            break
        if provider_quota_exhausted_today(provider):
            skipped_quota += 1
            continue
        try:
            answer = run_provider(provider, prompt)
        except Exception as exc:
            errors.append(f"{provider.get('name') or provider.get('id')}: {exc}")
            record_stat(provider, False, str(exc))
            continue
        record_stat(provider, True)
        used.append(provider)
        return answer, used, errors
    if not used and skipped_quota:
        errors.append(f"{skipped_quota} 条线路今天额度已耗尽，已跳过等待跨日恢复")
    return "", used, errors


def chat_completion_payload(model: str, text: str, identifier: str = "") -> dict[str, Any]:
    return {
        "id": identifier or f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def responses_payload(
    model: str, text: str, identifier: str = "", message_identifier: str = ""
) -> dict[str, Any]:
    message_id = message_identifier or f"msg_{uuid.uuid4().hex[:24]}"
    return {
        "id": identifier or f"resp_{uuid.uuid4().hex[:24]}",
        "object": "response",
        "created_at": int(time.time()),
        "model": model,
        "status": "completed",
        "output": [
            {
                "id": message_id,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
        "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
    }


def responses_payload_from_dsml(model: str, text: str) -> dict[str, Any] | None:
    calls, clean = parse_dsml_calls(text)
    if not calls:
        return None
    payload = responses_payload(model, clean)
    if not clean:
        payload["output"] = []
    payload["output"].extend(calls)
    return payload


def message_payload(model: str, text: str, identifier: str = "") -> dict[str, Any]:
    return {
        "id": identifier or f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [{"type": "text", "text": text}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0},
    }


def sse_chunks(shape: str, model: str, text: str) -> list[str]:
    """把整段回答包成单个 SSE 事件。

    本地模型走网关时客户端几乎都会带 stream=true；一个分片就够客户端
    正确收完，不必真做逐字流式。
    """
    if shape == "messages":
        return [
            sse_event(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": f"msg_{uuid.uuid4().hex[:24]}",
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [],
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                },
            ),
            sse_event(
                "content_block_start",
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            ),
            sse_event(
                "content_block_delta",
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
            ),
            sse_event("content_block_stop", {"type": "content_block_stop", "index": 0}),
            sse_event(
                "message_delta",
                {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 0}},
            ),
            sse_event("message_stop", {"type": "message_stop"}),
        ]
    if shape == "responses":
        identifier = f"resp_{uuid.uuid4().hex[:24]}"
        message_id = f"msg_{uuid.uuid4().hex[:24]}"
        part_id = f"part_{uuid.uuid4().hex[:24]}"
        completed_item = {
            "id": message_id,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}],
        }
        return [
            sse_event(
                "response.created",
                {
                    "type": "response.created",
                    "response": {
                        "id": identifier,
                        "object": "response",
                        "status": "in_progress",
                        "model": model,
                        "output": [],
                    },
                },
            ),
            sse_event(
                "response.in_progress",
                {
                    "type": "response.in_progress",
                    "response": {
                        "id": identifier,
                        "object": "response",
                        "status": "in_progress",
                        "model": model,
                        "output": [],
                    },
                },
            ),
            sse_event(
                "response.output_item.added",
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {
                        "id": message_id,
                        "type": "message",
                        "status": "in_progress",
                        "role": "assistant",
                        "content": [],
                    },
                },
            ),
            sse_event(
                "response.content_part.added",
                {
                    "type": "response.content_part.added",
                    "item_id": message_id,
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"id": part_id, "type": "output_text", "text": "", "annotations": []},
                },
            ),
            sse_event(
                "response.output_text.delta",
                {
                    "type": "response.output_text.delta",
                    "item_id": message_id,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": text,
                },
            ),
            sse_event(
                "response.output_text.done",
                {
                    "type": "response.output_text.done",
                    "item_id": message_id,
                    "output_index": 0,
                    "content_index": 0,
                    "text": text,
                },
            ),
            sse_event(
                "response.content_part.done",
                {
                    "type": "response.content_part.done",
                    "item_id": message_id,
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"id": part_id, "type": "output_text", "text": text, "annotations": []},
                },
            ),
            sse_event(
                "response.output_item.done",
                {
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": completed_item,
                },
            ),
            sse_event(
                "response.completed",
                {
                    "type": "response.completed",
                    "response": responses_payload(model, text, identifier, message_id),
                },
            ),
        ]
    identifier = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    return [
        "data: "
        + json.dumps(
            {
                "id": identifier,
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}],
            },
            ensure_ascii=False,
        )
        + "\n\n",
        "data: "
        + json.dumps(
            {
                "id": identifier,
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            },
            ensure_ascii=False,
        )
        + "\n\n",
        "data: [DONE]\n\n",
    ]


def sse_event(name: str, payload: dict[str, Any]) -> str:
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


DSML_INVOKE_RE = re.compile(
    r'(?s)(?:<｜{1,2}DSML｜{1,2}\s*|<)invoke\s+name="([^"]+)"\s*>(.*?)'
    r'</(?:｜{1,2}DSML｜{1,2}\s*)?invoke>'
)
DSML_PARAMETER_RE = re.compile(
    r'(?s)(?:<｜{1,2}DSML｜{1,2}\s*|<)parameter\s+name="([^"]+)"([^>]*)>(.*?)'
    r'</(?:｜{1,2}DSML｜{1,2}\s*)?parameter>'
)


def parse_dsml_calls(text: str) -> tuple[list[dict[str, Any]], str]:
    """Translate DeepSeek's native DSML/XML tool text to Responses calls."""
    calls: list[dict[str, Any]] = []
    for match in DSML_INVOKE_RE.finditer(text or ""):
        name = match.group(1).strip()
        arguments: dict[str, Any] = {}
        for parameter in DSML_PARAMETER_RE.finditer(match.group(2)):
            key = parameter.group(1).strip()
            attrs = parameter.group(2) or ""
            raw = parameter.group(3).strip()
            if 'string="true"' in attrs:
                value: Any = raw
            else:
                try:
                    value = json.loads(raw)
                except (TypeError, ValueError):
                    value = raw
            arguments[key] = value
        calls.append({
            "type": "function_call",
            "id": str(uuid.uuid4()),
            "status": "completed",
            "arguments": json.dumps(arguments, ensure_ascii=False),
            "call_id": f"call_{uuid.uuid4().hex[:24]}",
            "name": name,
        })
    if not calls:
        return [], text
    clean = DSML_INVOKE_RE.sub("", text or "")
    clean = re.sub(r"(?s)<(?:｜{1,2}DSML｜{1,2}\s*)?(?:calls|tool_calls)>|"
                   r"</(?:｜{1,2}DSML｜{1,2}\s*)?(?:calls|tool_calls)>", "", clean)
    return calls, clean.strip()


def normalize_dsml_response(payload: dict[str, Any]) -> dict[str, Any]:
    """Replace DSML message text inside a Responses JSON with function_call items."""
    output = payload.get("output")
    if not isinstance(output, list):
        return payload
    updated: list[dict[str, Any]] = []
    changed = False
    for item in output:
        if not isinstance(item, dict) or item.get("type") != "message":
            updated.append(item)
            continue
        calls: list[dict[str, Any]] = []
        kept_content: list[dict[str, Any]] = []
        for part in item.get("content") or []:
            if not isinstance(part, dict) or part.get("type") not in {"output_text", "text"}:
                kept_content.append(part)
                continue
            found, clean = parse_dsml_calls(str(part.get("text") or ""))
            calls.extend(found)
            if clean:
                kept_content.append({**part, "text": clean})
        if calls:
            changed = True
            if kept_content:
                updated.append({**item, "content": kept_content})
            updated.extend(calls)
        else:
            updated.append(item)
    if not changed:
        return payload
    return {**payload, "status": "completed", "output": updated}


def synthetic_responses_sse(payload: dict[str, Any]) -> str:
    """Emit a compact Responses SSE stream for a buffered compatibility response."""
    response_id = str(payload.get("id") or f"resp_{uuid.uuid4().hex}")
    base = {**payload, "id": response_id, "status": "in_progress", "output": []}
    chunks = [sse_event("response.created", {"type": "response.created", "response": base})]
    chunks.append(sse_event("response.in_progress", {"type": "response.in_progress", "response": base}))
    output = payload.get("output") if isinstance(payload.get("output"), list) else []
    for index, raw_item in enumerate(output):
        if not isinstance(raw_item, dict):
            continue
        item = dict(raw_item)
        item.setdefault("id", str(uuid.uuid4()))
        added_item = dict(item)
        if item.get("type") == "custom_tool_call":
            added_item["input"] = ""
        chunks.append(sse_event("response.output_item.added", {
            "type": "response.output_item.added", "item": added_item, "output_index": index,
        }))
        if item.get("type") == "function_call":
            arguments = str(item.get("arguments") or "")
            chunks.append(sse_event("response.function_call_arguments.delta", {
                "type": "response.function_call_arguments.delta", "delta": arguments,
                "item_id": item["id"], "output_index": index,
            }))
            chunks.append(sse_event("response.function_call_arguments.done", {
                "type": "response.function_call_arguments.done", "arguments": arguments,
                "item_id": item["id"], "output_index": index,
            }))
        elif item.get("type") == "custom_tool_call":
            input_text = str(item.get("input") or "")
            chunks.append(sse_event("response.custom_tool_call_input.delta", {
                "type": "response.custom_tool_call_input.delta", "delta": input_text,
                "item_id": item["id"], "output_index": index,
            }))
            chunks.append(sse_event("response.custom_tool_call_input.done", {
                "type": "response.custom_tool_call_input.done", "input": input_text,
                "item_id": item["id"], "output_index": index,
            }))
        elif item.get("type") == "message":
            for content_index, part in enumerate(item.get("content") or []):
                if not isinstance(part, dict):
                    continue
                text = str(part.get("text") or "")
                chunks.append(sse_event("response.content_part.added", {
                    "type": "response.content_part.added", "item_id": item["id"],
                    "output_index": index, "content_index": content_index, "part": part,
                }))
                if text:
                    chunks.append(sse_event("response.output_text.delta", {
                        "type": "response.output_text.delta", "delta": text,
                        "item_id": item["id"], "output_index": index,
                        "content_index": content_index,
                    }))
                chunks.append(sse_event("response.output_text.done", {
                    "type": "response.output_text.done", "text": text,
                    "item_id": item["id"], "output_index": index,
                    "content_index": content_index,
                }))
                chunks.append(sse_event("response.content_part.done", {
                    "type": "response.content_part.done", "item_id": item["id"],
                    "output_index": index, "content_index": content_index, "part": part,
                }))
        chunks.append(sse_event("response.output_item.done", {
            "type": "response.output_item.done", "item": item, "output_index": index,
        }))
    completed = {**payload, "id": response_id, "status": "completed", "output": output}
    chunks.append(sse_event("response.completed", {"type": "response.completed", "response": completed}))
    return "".join(chunks)


# ---------------------------------------------------------------- 原样透传
# 带 tools 的请求（Codex 这类 agent 客户端）必须原样转发：一旦被压成纯文本，
# function_call / usage / reasoning 这些结构化字段就丢了，客户端只能拿到一段
# 没法执行的文字。这里只改 model，并按线路要求调整 stream，其余字段一律不动，
# 上游回什么就转什么（SSE 逐行转发，JSON 原样回写）。
PASSTHROUGH_HEADER = "X-Unified-Router-Passthrough"


def wants_tool_passthrough(body: dict[str, Any], headers: Any) -> bool:
    switch = str(headers.get(PASSTHROUGH_HEADER) or "").strip().lower()
    if switch in {"1", "true", "yes", "on"}:
        return True
    if body.get("tool_choice"):
        return True
    tools = body.get("tools")
    return isinstance(tools, list) and bool(tools)


def responses_to_chat_tool_payload(body: dict[str, Any], model: str) -> dict[str, Any]:
    """Downgrade a Codex Responses request to DeepSeek Chat Completions."""
    messages: list[dict[str, Any]] = []
    reasoning_content = ""
    instructions = str(body.get("instructions") or "").strip()
    if instructions:
        messages.append({"role": "system", "content": instructions})
    raw_input = body.get("input")
    if isinstance(raw_input, str) and raw_input.strip():
        messages.append({"role": "user", "content": raw_input})
    elif isinstance(raw_input, list):
        for item in raw_input:
            if not isinstance(item, dict):
                continue
            item_type = str(item.get("type") or "")
            if item_type == "reasoning":
                summary = item.get("summary")
                if isinstance(summary, list):
                    reasoning_content = "\n".join(
                        str(part.get("text") or "")
                        for part in summary
                        if isinstance(part, dict) and part.get("text")
                    ).strip()
                continue
            if item_type in {"function_call_output", "custom_tool_call_output"}:
                output = item.get("output")
                if not isinstance(output, str):
                    output = json.dumps(output, ensure_ascii=False)
                messages.append({
                    "role": "tool",
                    "tool_call_id": str(item.get("call_id") or ""),
                    "content": output,
                })
                continue
            if item_type in {"function_call", "custom_tool_call"}:
                call_name = str(item.get("name") or "")
                call_arguments = str(item.get("arguments") or "{}")
                if item_type == "custom_tool_call":
                    call_arguments = json.dumps(
                        {"input": str(item.get("input") or "")}, ensure_ascii=False
                    )
                if call_name == "exec":
                    # Codex custom tools use the raw grammar source as the
                    # function-call argument.  DeepSeek Chat needs JSON, so
                    # wrap a returned raw source back into {input: ...}.
                    try:
                        parsed_arguments = json.loads(call_arguments)
                    except (TypeError, ValueError):
                        parsed_arguments = None
                    if not isinstance(parsed_arguments, dict) or "input" not in parsed_arguments:
                        call_arguments = json.dumps(
                            {"input": call_arguments}, ensure_ascii=False
                        )
                assistant_message = {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": str(item.get("call_id") or item.get("id") or "call_unknown"),
                        "type": "function",
                        "function": {
                            "name": call_name,
                            "arguments": call_arguments,
                        },
                    }],
                }
                if reasoning_content:
                    assistant_message["reasoning_content"] = reasoning_content
                messages.append(assistant_message)
                continue
            role = str(item.get("role") or "user")
            # DeepSeek Chat Completions 不接受 Responses 的 developer 角色；
            # 这类约束/项目指令在降级线路上等价放进 system。
            if role == "developer":
                role = "system"
            content = item.get("content")
            if isinstance(content, list):
                text = "\n".join(
                    str(part.get("text") or part.get("content") or "")
                    for part in content
                    if isinstance(part, dict)
                ).strip()
                content = text
            if isinstance(content, str) and content.strip():
                messages.append({"role": role, "content": content})
    tools: list[dict[str, Any]] = []
    for tool in body.get("tools") or []:
        if not isinstance(tool, dict):
            continue
        tool_type = str(tool.get("type") or "")
        if tool_type == "custom" and isinstance(tool.get("name"), str):
            # Responses custom tools (notably Codex's JavaScript `exec`) have
            # a grammar rather than JSON Schema.  DeepSeek Chat only accepts
            # function tools, so expose the raw program as an `input` string.
            tools.append({
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool.get("description") or "",
                    "parameters": {
                        "type": "object",
                        "properties": {"input": {"type": "string"}},
                        "required": ["input"],
                        "additionalProperties": False,
                    },
                },
            })
        elif tool_type == "function" and isinstance(tool.get("name"), str):
            tools.append({
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool.get("description") or "",
                    "parameters": tool.get("parameters") or {"type": "object"},
                },
            })
    payload: dict[str, Any] = {"model": model, "messages": messages, "stream": False}
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    return payload


def chat_to_responses_payload(
    payload: dict[str, Any], model: str, custom_tools: set[str] | None = None
) -> dict[str, Any]:
    """Chat Completions 响应 → Responses 响应。

    ``custom_tools`` 是本次请求里 type=custom 的工具名集合。Responses 的 custom
    工具必须回成 ``custom_tool_call``，否则 Codex 会报
    “tool <name> invoked with incompatible payload”。Codex 0.155 起除了 JS
    `exec` 还有 custom 的 `apply_patch`，所以不能只认死名字。
    """
    custom_names = {str(name) for name in (custom_tools or set()) if name}
    custom_names.add("exec")  # 兼容旧目录：JS exec 永远是 custom 工具
    choices = payload.get("choices") if isinstance(payload.get("choices"), list) else []
    message = choices[0].get("message") if choices and isinstance(choices[0], dict) else {}
    output: list[dict[str, Any]] = []
    reasoning_content = message.get("reasoning_content") if isinstance(message, dict) else ""
    if isinstance(reasoning_content, str) and reasoning_content.strip():
        output.append({
            "type": "reasoning",
            "id": f"rs_{uuid.uuid4().hex[:24]}",
            "status": "completed",
            "summary": [{"type": "summary_text", "text": reasoning_content}],
        })
    content = message.get("content") if isinstance(message, dict) else ""
    if isinstance(content, str) and content.strip():
        calls, clean = parse_dsml_calls(content)
        if clean:
            output.append({
                "id": f"msg_{uuid.uuid4().hex[:24]}", "type": "message",
                "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": clean, "annotations": []}],
            })
        output.extend(calls)
    for raw_call in (message.get("tool_calls") if isinstance(message, dict) else []) or []:
        if not isinstance(raw_call, dict):
            continue
        function = raw_call.get("function") or {}
        call_name = str(function.get("name") or "")
        call_arguments = str(function.get("arguments") or "{}")
        if call_name in custom_names:
            # Responses custom tools expect the grammar source directly,
            # while Chat Completions returns our compatibility wrapper.
            try:
                parsed_arguments = json.loads(call_arguments)
            except (TypeError, ValueError):
                parsed_arguments = None
            if isinstance(parsed_arguments, dict) and isinstance(parsed_arguments.get("input"), str):
                call_arguments = parsed_arguments["input"]
        call_id = str(raw_call.get("id") or f"call_{uuid.uuid4().hex[:24]}")
        if call_name in custom_names:
            output.append({
                "type": "custom_tool_call",
                "id": str(raw_call.get("id") or uuid.uuid4()),
                "status": "completed",
                "call_id": call_id,
                "name": call_name,
                "input": call_arguments,
            })
        else:
            output.append({
                "type": "function_call",
                "id": str(raw_call.get("id") or uuid.uuid4()),
                "status": "completed",
                "arguments": call_arguments,
                "call_id": call_id,
                "name": call_name,
            })
    raw_usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    usage = dict(raw_usage)
    # Chat Completions uses prompt/completion_tokens; Codex's Responses parser
    # requires input/output_tokens even when the upstream omits usage entirely.
    usage.setdefault("input_tokens", usage.get("prompt_tokens", 0))
    usage.setdefault("output_tokens", usage.get("completion_tokens", 0))
    usage.setdefault(
        "total_tokens",
        usage.get("input_tokens", 0) + usage.get("output_tokens", 0),
    )
    return {
        "id": str(payload.get("id") or f"resp_{uuid.uuid4().hex[:24]}"),
        "object": "response", "status": "completed", "model": model,
        "output": output, "usage": usage,
    }


def normalize_dsml_chat(payload: dict[str, Any]) -> dict[str, Any]:
    choices = payload.get("choices") if isinstance(payload.get("choices"), list) else []
    if not choices or not isinstance(choices[0], dict):
        return payload
    choice = choices[0]
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    content = message.get("content") if isinstance(message, dict) else ""
    calls, clean = parse_dsml_calls(str(content or ""))
    if not calls:
        return payload
    tool_calls = [
        {
            "id": call["call_id"], "type": "function",
            "function": {"name": call["name"], "arguments": call["arguments"]},
        }
        for call in calls
    ]
    updated_message = {**message, "content": clean or None, "tool_calls": tool_calls}
    return {**payload, "choices": [{**choice, "message": updated_message, "finish_reason": "tool_calls"}]}


def synthetic_chat_sse(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") if isinstance(payload.get("choices"), list) else []
    message = choices[0].get("message") if choices and isinstance(choices[0], dict) else {}
    tool_calls = message.get("tool_calls") if isinstance(message, dict) else []
    chunks: list[str] = []
    if isinstance(tool_calls, list):
        for index, call in enumerate(tool_calls):
            function = call.get("function") or {}
            delta = {"tool_calls": [{
                "index": index, "id": call.get("id"), "type": "function",
                "function": {"name": function.get("name"), "arguments": function.get("arguments") or ""},
            }]}
            chunks.append("data: " + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]}, ensure_ascii=False) + "\n\n")
    chunks.append("data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}, ensure_ascii=False) + "\n\n")
    chunks.append("data: [DONE]\n\n")
    return "".join(chunks)


def passthrough_wire_matches(provider: dict[str, Any], shape: str) -> bool:
    """协议形状一致才能原样转发；跨协议（Claude 的 /messages）继续走老路径。"""
    if is_anthropic_wire(provider):
        return False
    if not str(provider.get("base_url") or "").strip():
        return False
    if shape == "responses":
        provider_text = " ".join(
            str(provider.get(key) or "")
            for key in ("id", "name", "model", "source", "base_url")
        ).lower()
        return is_responses_wire(provider) or "deepseek" in provider_text
    if shape == "chat":
        return not is_responses_wire(provider)
    return False


def upstream_endpoint(base_url: str, shape: str) -> str:
    url = base_url.rstrip("/")
    suffix = "/responses" if shape == "responses" else "/chat/completions"
    return url if url.endswith(suffix) else url + suffix


def collect_responses_sse(raw: bytes) -> dict[str, Any] | None:
    """线路只肯给流式时，把最后的 response.completed 还原成一次性 JSON。"""
    for block in raw.decode("utf-8", "replace").split("\n\n"):
        payloads = [
            line[5:].strip()
            for line in block.splitlines()
            if line.startswith("data:")
        ]
        if not payloads:
            continue
        try:
            event = json.loads("".join(payloads))
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("type") == "response.completed":
            response = event.get("response")
            if isinstance(response, dict):
                return response
    return None


class GatewayHandler(BaseHTTPRequestHandler):
    """OpenAI 兼容入口：客户端只认这一个地址，具体走哪条线路由 Agent 决定。"""

    protocol_version = "HTTP/1.1"
    server_version = "UnifiedRouterGateway/1.0"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - 基类签名
        return  # 日志由宿主进程收集，这里保持安静

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_sse(self, chunks: list[str]) -> None:
        body = "".join(chunks).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---- 原样透传：让 Codex 这类客户端拿到 function_call / usage 等结构化字段 ----

    def _relay_headers(self, provider: dict[str, Any]) -> dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream, application/json",
        }
        api_key = resolve_api_key(provider)
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        for key, value in (provider.get("headers") or {}).items():
            headers[str(key)] = str(value)
        return headers

    def _relay_upstream(self, upstream: Any, client_stream: bool) -> None:
        content_type = str(upstream.headers.get("Content-Type") or "").strip()
        # 流式响应没法预先给出长度：用「Connection: close + 读到 EOF」界定 body，
        # 这样还能逐行把上游的 SSE 原样吐出去，客户端能实时看到增量。
        self.close_connection = True
        if client_stream:
            self.send_response(200)
            self.send_header("Content-Type", content_type or "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            for line in upstream:
                self.wfile.write(line)
                self.wfile.flush()
            return
        # 一次性回答：先把上游读完、必要时聚合完，再决定内容 —— 这样失败时
        # 一个字节都还没写给客户端，还能换下一条线路。
        raw = upstream.read()
        if "text/event-stream" in content_type.lower():
            payload = collect_responses_sse(raw)
            if payload is None:
                raise RuntimeError("线路只接受流式返回，无法还原成一次性回答")
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type or "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _relay_passthrough(
        self, shape: str, providers: list[dict[str, Any]], body: dict[str, Any]
    ) -> bool:
        """按顺序挑一条同协议的线路原样转发；返回 True 表示已经回复过客户端。"""
        all_candidates = [p for p in providers if passthrough_wire_matches(p, shape)]
        if not all_candidates:
            return False
        candidates = [p for p in all_candidates if not provider_quota_exhausted_today(p)]
        if not candidates:
            labels = "、".join(str(p.get("name") or p.get("id") or "线路") for p in all_candidates)
            self._error(
                429,
                f"当前模型线路今天额度已耗尽：{labels}；跨日后自动恢复探测",
                "quota_exhausted",
            )
            return True
        client_stream = bool(body.get("stream"))
        tools_count = len(body.get("tools")) if isinstance(body.get("tools"), list) else 0
        errors: list[str] = []

        def note(provider: dict[str, Any], model: str, result: str, seconds: float | None = None) -> None:
            """排障用：dsh/客户端第一次走新协议时，这一行能看出发的是哪条线路。"""
            host = urlparse(str(provider.get("base_url") or "")).netloc or "官方直连"
            cost = f" {seconds:.2f}s" if seconds is not None else ""
            print(
                f"[passthrough] {shape} tools={tools_count} model={model} host={host} "
                f"client_stream={str(client_stream).lower()} -> {result}{cost}",
                file=sys.stderr,
                flush=True,
            )
        for provider in candidates:
            label = provider.get("name") or provider.get("id")
            model = str(provider.get("model") or "").strip()
            if not model:
                errors.append(f"{label}: 缺少模型名")
                continue
            payload = dict(body)
            payload["model"] = model
            # DeepSeek 的 Responses 适配器不接受 Codex 的强制 tool_choice，
            # 会把 DSML 工具标记（<｜DSML｜ invoke ...>）当普通文本吐回来。
            # 保留完整 tools，只把选择策略降为 auto；模型仍会正常返回结构化
            # function_call，而不会把内部 DSML 协议泄漏给 Codex。
            provider_text = " ".join(
                str(provider.get(key) or "")
                for key in ("id", "name", "model", "source", "base_url")
            ).lower()
            # DeepSeek 的工具响应需要先完整收集，不能把上游正文直接逐字节
            # 转给 Codex；同时这个标志决定是否要跨到 Chat Completions。
            # 本次请求里 type=custom 的工具名（exec / apply_patch …）要在还原
            # 响应时回成 custom_tool_call，否则 Codex 会判定 payload 不兼容。
            custom_tool_names = {
                str(tool.get("name"))
                for tool in (body.get("tools") or [])
                if isinstance(tool, dict)
                and str(tool.get("type") or "") == "custom"
                and tool.get("name")
            }
            deepseek_tools = "deepseek" in provider_text and (
                bool(body.get("tools"))
                or bool(body.get("tool_choice"))
                or wants_tool_passthrough(body, self.headers)
            )
            # DeepSeek 的 /responses 端点目前只接受它自己的受限工具形状；
            # Codex 会传入 exec / apply_patch 等通用工具，直接发 Responses
            # 会得到 400（Only 'apply_patch' is supported）。只对「带工具」
            # 的请求走 Chat Completions，再在下面还原成 Responses；普通无
            # 工具请求仍保持原线路协议。
            cross_protocol = (
                shape == "responses"
                and "deepseek" in provider_text
                and deepseek_tools
            )
            relay_shape = "chat" if cross_protocol else shape
            if cross_protocol:
                payload = responses_to_chat_tool_payload(payload, model)
            if "deepseek" in provider_text and payload.get("tool_choice"):
                payload["tool_choice"] = "auto"
            if "deepseek" in provider_text and payload.get("tools"):
                protocol_note = (
                    "Tool protocol requirement: use only the structured function-call "
                    "interface supplied in this request. Never emit DSML, XML, "
                    "<tool_calls>, <invoke>, or tool markup as assistant text."
                )
                if relay_shape == "chat":
                    messages = payload.setdefault("messages", [])
                    if messages and messages[0].get("role") == "system":
                        messages[0]["content"] = (
                            str(messages[0].get("content") or "").rstrip()
                            + "\n\n"
                            + protocol_note
                        )
                    else:
                        messages.insert(0, {"role": "system", "content": protocol_note})
                else:
                    instructions = str(payload.get("instructions") or "")
                    payload["instructions"] = instructions + "\n\n" + protocol_note
            # DeepSeek 的工具文本需要先完整收集，解析 DSML/XML 后再合成
            # Responses function_call SSE；其它线路保持原来的实时透传。
            # 线路要么本来就要 SSE（本地 Codex Router 不接受一次性 JSON），
            # 要么就跟着客户端走。
            payload["stream"] = False if deepseek_tools else (client_stream or bool(provider.get("stream")))
            request = urllib.request.Request(
                upstream_endpoint(str(provider.get("base_url") or ""), relay_shape),
                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                headers=self._relay_headers(provider),
                method="POST",
            )
            timeout = float(provider.get("timeout_seconds") or DEFAULT_TIMEOUT)
            started = time.time()
            try:
                upstream = urllib.request.urlopen(request, timeout=timeout)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:600]
                message = f"HTTP {exc.code}: {detail}"
                errors.append(f"{label}: {message}")
                note(provider, model, f"HTTP {exc.code} {detail[:220]}")
                record_stat(provider, False, message)
                continue
            except urllib.error.URLError as exc:
                message = f"网络错误：{exc.reason}"
                errors.append(f"{label}: {message}")
                note(provider, model, message)
                record_stat(provider, False, message)
                continue
            except (OSError, TimeoutError) as exc:
                message = f"连接失败：{exc}"
                errors.append(f"{label}: {message}")
                note(provider, model, message)
                record_stat(provider, False, message)
                continue
            # 上游已经接住了：此刻起必须由这条线路把响应送出去，不能再换线。
            record_stat(provider, True)
            try:
                with upstream:
                    if deepseek_tools:
                        raw = upstream.read()
                        response = json.loads(raw.decode("utf-8", "replace"))
                        if cross_protocol:
                            response = chat_to_responses_payload(response, model, custom_tool_names)
                            response = normalize_dsml_response(response)
                        elif shape == "chat":
                            response = normalize_dsml_chat(response)
                        if client_stream:
                            self._send_sse([
                                synthetic_responses_sse(response)
                                if shape == "responses"
                                else synthetic_chat_sse(response)
                            ])
                        else:
                            self._send_json(200, response)
                    else:
                        self._relay_upstream(upstream, client_stream)
                note(provider, model, "ok", time.time() - started)
            except RuntimeError as exc:
                # 这条 line 只在写响应头之前抛出，还能继续试下一条线路。
                errors.append(f"{label}: {exc}")
                note(provider, model, f"未回包：{exc}")
                record_stat(provider, False, str(exc))
                continue
            except OSError:
                # 客户端中途断开或上游半路掉线：响应头早发出去了，只能就此收尾，
                # 由客户端自己决定要不要重试。
                pass
            return True
        # 带工具的请求全部失败时，先降级成「不带工具」的纯文本再试一次：至少让
        # 用户拿到同一模型的回答，而不是因为某个工具形状被上游拒绝就整轮 502。
        # 官方直连的 DeepSeek 也只有在 function 工具上才稳定，Codex 的 exec 等
        # custom 工具本来就是转译后发的，转译边界出错时这条路兜底。
        had_tools = isinstance(body.get("tools"), list) and bool(body.get("tools"))
        if had_tools:
            stripped = {
                key: value
                for key, value in body.items()
                if key not in ("tools", "tool_choice")
            }
            print(
                f"[passthrough] {shape} 带工具全部失败，降级为纯文本重试（tools={len(body.get('tools'))}）",
                file=sys.stderr,
                flush=True,
            )
            return self._relay_passthrough(shape, providers, stripped)
        print(
            f"[passthrough] {shape} 全部线路失败：{'；'.join(errors)[:300]}",
            file=sys.stderr,
            flush=True,
        )
        # 上游是「额度用尽 / 限流」时必须原样回 429：折成 502 会让 Codex 把
        # 额度问题当成网关故障，连着重试 5 次并只显示 Bad Gateway，用户看不到
        # 真实原因（例如 ChatGPT 订阅的 usage_limit_reached）。
        if errors and all("HTTP 429" in item for item in errors):
            self._error(429, "；".join(errors)[:600], "upstream_rate_limited")
            return True
        self._error(502, "；".join(errors)[:600] or "所有线路都不可用", "upstream_error")
        return True

    def _route_path(self) -> tuple[str | None, str]:
        path = urlparse(self.path).path.rstrip("/")
        if path.startswith("/agents/"):
            parts = path.split("/")
            if len(parts) >= 4 and parts[3] == "v1":
                return unquote(parts[2]), "/" + "/".join(parts[3:])
        return None, path

    def _error(self, status: int, message: str, kind: str = "invalid_request_error") -> None:
        self._send_json(status, {"error": {"message": message, "type": kind, "code": status}})

    def _authorized(self) -> bool:
        # 密钥永远以 router.json 为准：--serve 的临时覆盖只管监听地址和默认 Agent。
        config = ensure_config()
        expected = ensure_gateway_key(config)
        header = str(self.headers.get("Authorization") or "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else header.strip()
        for candidate in (token, self.headers.get("x-api-key"), self.headers.get("api-key")):
            if candidate and str(candidate).strip() == expected:
                return True
        return False

    def do_GET(self) -> None:  # noqa: N802 - 基类命名
        requested_agent, path = self._route_path()
        if path in {"/health", "/v1/health", ""}:
            info = gateway_info(gateway_view())
            self._send_json(
                200,
                {
                    "status": "ok",
                    "gateway": info["base_url"],
                    "agent": info["resolved_agent"],
                    "providers": len(info["providers"]),
                },
            )
            return
        if path in {"/v1/models", "/models"}:
            if not self._authorized():
                self._error(401, "网关密钥无效", "authentication_error")
                return
            config = gateway_view()
            agent_id, providers = gateway_routes(config, requested_agent)
            if agent_id == "default":
                picker_models = codex_picker_models(config)
                self._send_json(
                    200,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": str(row["slug"]),
                                "object": "model",
                                "owned_by": "codex"
                                if str(row["slug"]).lower().startswith(("gpt-", "codex-"))
                                else "ai-assistant",
                                "name": str(row.get("display_name") or row["slug"]),
                            }
                            for row in picker_models
                        ],
                    },
                )
                return
            catalog_providers = external_model_catalog(providers)
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": agent_id, "object": "model", "owned_by": "unified-router"},
                        *[
                            {
                                "id": external_model_name(provider) or str(provider.get("id")),
                                "object": "model",
                                "owned_by": str(provider.get("source_name") or provider.get("source") or "unified-router"),
                                "name": "Jev / 4202"
                                if external_model_name(provider) == JEV_INTERNAL_MODEL
                                else str(provider.get("name") or provider.get("id") or ""),
                            }
                            for provider in catalog_providers
                        ],
                    ],
                },
            )
            return
        self._error(404, f"未知路径：{path}", "not_found")

    def do_POST(self) -> None:  # noqa: N802 - 基类命名
        raw = b""
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                raw = self.rfile.read(length)
        except (TypeError, ValueError):
            raw = b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            self._error(400, "请求体不是合法 JSON")
            return
        if not isinstance(body, dict):
            self._error(400, "请求体必须是 JSON 对象")
            return
        if not self._authorized():
            self._error(401, "网关密钥无效", "authentication_error")
            return
        path_agent, path = self._route_path()
        if path.endswith("/chat/completions"):
            shape = "chat"
        elif path.endswith("/responses"):
            shape = "responses"
        elif path.endswith("/messages"):
            shape = "messages"
        else:
            self._error(404, f"未知路径：{path}", "not_found")
            return
        prompt = gateway_prompt(body)
        if not prompt:
            self._error(400, "请求里没有可用的提示词")
            return
        requested_agent = path_agent or str(self.headers.get("X-Unified-Router-Agent") or "").strip()
        config = gateway_view()
        settings = gateway_settings(config)
        agent_id, providers = gateway_routes(
            config, requested_agent or str(settings.get("agent_id") or "")
        )
        if not providers:
            self._error(503, f"Agent「{agent_id}」没有已启用的供应商", "no_provider")
            return
        requested_model = str(body.get("model") or "").strip()
        if requested_model and requested_model not in {agent_id, "auto", "default"}:
            aliases = {requested_model}
            if requested_model.startswith("ai-assistant/"):
                aliases.add(requested_model.removeprefix("ai-assistant/"))
            assigned_codex = {
                item.casefold() for item in client_assignment_models(config, "codex")
            }
            prefer_native = (
                agent_id == "default"
                and is_native_codex_model(requested_model)
                and requested_model.casefold() not in assigned_codex
            )
            matches = [] if prefer_native else [
                index for index, provider in enumerate(providers)
                if str(provider.get("id") or "") in aliases
                or str(provider.get("model") or "") in aliases
                or external_model_name(provider) in aliases
            ]
            if prefer_native or not matches:
                native = (
                    native_codex_relay_provider(config, requested_model)
                    if is_native_codex_model(requested_model)
                    else None
                )
                if native is None:
                    self._error(400, f"模型「{requested_model}」不属于 Agent「{agent_id}」", "unknown_model")
                    return
                providers = [native]
            else:
                # provider_ids 是 Agent 的模型池顺序，不是跨模型故障转移链。
                # 固定模型只能在同名线路之间切换；JEV 则只保留 JEV 入口，
                # 由 JEV 自己决定真实模型，不能在 JEV 失败后静默落到别的固定模型。
                first = matches[0]
                target_model = external_model_name(providers[first]).strip().casefold()
                same_model_indices = [
                    index for index, provider in enumerate(providers)
                    if external_model_name(provider).strip().casefold() == target_model
                ]
                ordered_indices = [first] + [
                    index for index in same_model_indices if index != first
                ]
                providers = [providers[index] for index in ordered_indices]
        if shape == "responses" or wants_tool_passthrough(body, self.headers):
            # responses（Codex）和带工具的请求都原样转发：保住 tools、function_call、
            # usage、reasoning 等结构化字段；只有 chat 纯文本（语音）链路才落回
            # run_chain。之前无工具的 responses 也走 run_chain，会把 DeepSeek 的
            # reasoning_content 拼进正文，导致答案前带「We need answer...」前导语。
            if self._relay_passthrough(shape, providers, body):
                return
        text, _, errors = run_chain(providers, prompt)
        if not text:
            self._error(502, "；".join(errors)[:600] or "所有线路都不可用", "upstream_error")
            return
        model = str(body.get("model") or "").strip() or str(providers[0].get("model") or agent_id)
        # DeepSeek/其它兼容层偶尔会把原生 DSML 工具标记作为普通正文返回。
        # 在最后一道纯文本兜底处再识别一次，避免 Codex 看到 XML 而无法执行工具。
        if shape == "responses":
            converted = responses_payload_from_dsml(model, text)
            if converted is not None:
                if body.get("stream"):
                    self._send_sse([synthetic_responses_sse(converted)])
                else:
                    self._send_json(200, converted)
                return
        if shape == "chat":
            converted_calls, clean = parse_dsml_calls(text)
            if converted_calls:
                converted = {
                    "id": f"chatcmpl_{uuid.uuid4().hex[:24]}",
                    "object": "chat.completion", "model": model,
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant", "content": clean or None,
                            "tool_calls": [{
                                "id": call["call_id"], "type": "function",
                                "function": {"name": call["name"], "arguments": call["arguments"]},
                            } for call in converted_calls],
                        },
                        "finish_reason": "tool_calls",
                    }],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
                }
                if body.get("stream"):
                    self._send_sse([synthetic_chat_sse(converted)])
                else:
                    self._send_json(200, converted)
                return
        payload = (
            chat_completion_payload(model, text)
            if shape == "chat"
            else responses_payload(model, text)
            if shape == "responses"
            else message_payload(model, text)
        )
        if body.get("stream"):
            self._send_sse(sse_chunks(shape, model, text))
            return
        self._send_json(200, payload)


def gateway_overrides(
    settings: dict[str, Any], host: Any = None, port: Any = None, agent_id: Any = None
) -> tuple[str, int, dict[str, Any]]:
    """把 `--serve` 的临时覆盖叠到设置上并校验。返回（host, port, 覆盖字典）。

    这里只在内存里算，不碰 router.json：改端口不改配置，重启就回到原样。
    校验失败抛 RuntimeError，调用方翻成人话打给用户。
    """
    overrides: dict[str, Any] = {}
    if host is not None:
        text = str(host).strip()
        if not text:
            raise RuntimeError("--host 不能是空字符串（本机自用填 127.0.0.1）")
        overrides["host"] = text
    if port is not None:
        text = str(port).strip()
        if not text.lstrip("-").isdigit():
            raise RuntimeError(f"--port 要填数字，收到的是：{text!r}")
        number = int(text)
        # 0 是合法值：让系统挑一个空闲端口（自检和「同时开两个网关」都用得上）。
        if not 0 <= number <= 65535:
            raise RuntimeError(f"--port 要在 0-65535 之间（0 = 自选空闲端口），收到的是：{number}")
        overrides["port"] = number
    if agent_id is not None:
        text = str(agent_id).strip()
        if not text:
            raise RuntimeError("--agent-id 不能是空字符串（要回落默认链就别传这个参数）")
        overrides["agent_id"] = text
    return (
        str(overrides.get("host") or settings.get("host") or GATEWAY_DEFAULT_HOST),
        int(overrides.get("port", int(settings.get("port") or GATEWAY_DEFAULT_PORT))),
        overrides,
    )


def open_gateway(
    settings: dict[str, Any], overrides: dict[str, Any] | None = None
) -> tuple[ThreadingHTTPServer, dict[str, Any], str]:
    """绑定端口并装好临时覆盖；返回（服务器, 生效设置, 真实地址）。

    调用方负责 serve_forever / shutdown。自检走的也是这条路，所以「自检过的」
    就是「真启动时的」那条路径。
    """
    effective = dict(settings)
    effective.update(overrides or {})
    # 端口要单独取值：0 是「让系统挑空闲端口」的合法请求，不能被 or 兜底成默认值。
    raw_port = effective.get("port")
    port_number = GATEWAY_DEFAULT_PORT if raw_port in (None, "") else int(raw_port)
    host_text = str(effective.get("host") or GATEWAY_DEFAULT_HOST)
    # 先把密钥落定：网关起来之后只读配置、不再写盘，临时覆盖也就没机会被写回去。
    ensure_gateway_key(ensure_config())
    try:
        server = ThreadingHTTPServer((host_text, port_number), GatewayHandler)
    except OSError as exc:
        raise RuntimeError(f"{host_text}:{port_number} 不可用（{exc}）") from exc
    server.daemon_threads = True
    bound_host, bound_port = str(server.server_address[0]), int(server.server_address[1])
    # 覆盖记「真实」地址而不是「请求」的地址：--port 0 时端口是系统挑的，
    # 若还留着 0，/health 报出去的地址就成了假话。
    GATEWAY_OVERRIDES.clear()
    GATEWAY_OVERRIDES.update(
        {
            "host": bound_host,
            "port": bound_port,
            "agent_id": str(effective.get("agent_id") or "omni"),
        }
    )
    effective["host"], effective["port"] = bound_host, bound_port
    return server, effective, f"http://{bound_host}:{bound_port}/v1"


def serve_gateway(
    settings: dict[str, Any], host: Any = None, port: Any = None, agent_id: Any = None
) -> int:
    try:
        _, _, overrides = gateway_overrides(settings, host, port, agent_id)
        server, effective, base_url = open_gateway(settings, overrides)
    except RuntimeError as exc:
        print(f"网关启动失败：{exc}", file=sys.stderr)
        return 2
    # 报出来的 Agent 要跟 /health 一致（都要先过一遍回落链）：名字对不上时，
    # 用户看到的就是「日志说 omni、探活说 default」这种没法排查的场面。
    agent_label = str(effective.get("agent_id") or "omni")
    try:
        agent_label = gateway_routes(gateway_view(), agent_label)[0]
    except Exception:
        pass
    print(
        json.dumps(
            {
                # 报的是绑成功之后的真实地址：端口冲突早就退出了，这里不会骗人。
                "gateway": base_url,
                "agent": agent_label,
                "pid": os.getpid(),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--agent",
        default=None,
        help="Agent id（缺省用 router.json 的 assistant_agent，其次 omni，最后 default）",
    )
    parser.add_argument(
        "--budget",
        type=float,
        default=DEFAULT_BUDGET,
        help="整轮故障转移的总秒数上限，用完就不再试后面的线路",
    )
    parser.add_argument("--provider", help="只走这一条供应商（GUI 测试用）")
    parser.add_argument("--fetch-models", action="store_true", help="从 stdin 读取供应商连接配置并安全读取 /models")
    parser.add_argument("--probe-all-connections", action="store_true", help="通过 GET /models 测所有 HTTP 供应商的延迟和连通")
    parser.add_argument("--probe-models", action="store_true", help="对 HTTP 供应商各发一次极小生成请求，验鉴权/模型名并确认真能出字")
    parser.add_argument("--models-self-test", action="store_true", help="离线验证 URL 模型发现和测速")
    parser.add_argument("--gateway-listen-self-test", action="store_true", help="离线验证 --serve 的临时监听覆盖与 /health 自报地址")
    parser.add_argument("--discover-agents", action="store_true", help="只读扫描 Codex/ZCode/OpenCode/Claude Code Agent 配置")
    parser.add_argument("--sync-agent", action="store_true", help="将一个外部客户端指向本地指定 Agent 网关")
    parser.add_argument("--sync-client", default="", help="同步目标：codex 或 zcode")
    parser.add_argument("--sync-path", default="", help="目标客户端配置文件路径")
    parser.add_argument("--sync-agent-id", default="", help="router.json 中的 Agent id")
    parser.add_argument("--add-agent-model", action="store_true", help="把一个供应商模型交给 Codex/ZCode：绑线路到它的 Agent 并改客户端配置")
    parser.add_argument("--plan-agent-model", action="store_true", help="只预览：把模型加进客户端会改哪些文件（真实 diff，不写盘）")
    parser.add_argument("--agents", action="store_true",
                        help="三类 id 一张表：① Agent + ② 客户端清单 + ③ 本地检测到的（只读）")
    parser.add_argument("--agent-models", action="store_true",
                        help="每个 Agent 的每条线路一行，带真实 base_url（不写盘）")
    parser.add_argument("--agent-id", default="", help="配合 --agent-models：只看这个 Agent（留空 = 全部）；配合 --serve：临时改网关默认 Agent")
    parser.add_argument("--export", action="store_true", help="配合 --agents / --agent-models：输出机器可读 JSON")
    parser.add_argument("--agents-self-test", action="store_true", help="离线自检：三类 id、白名单、写入与备份")
    parser.add_argument("--agent-model-self-test", action="store_true", help="离线验证「加模型」同时改客户端与 Agent")
    parser.add_argument("--provider-id", default="", help="模型池里的线路 id（推荐：直接用已配置好的线路，不复制配置）")
    parser.add_argument("--model", default="", help="要添加的模型 ID")
    parser.add_argument("--provider-name", default="", help="供应商显示名")
    parser.add_argument("--provider-url", default="", help="供应商 Base URL")
    parser.add_argument("--provider-key", default="", help="供应商 API Key（仅进本地配置文件）")
    parser.add_argument("--provider-wire", default="chat_completions", help="供应商协议")
    parser.add_argument("--doctor", action="store_true")
    parser.add_argument("--import-dsh", action="store_true", help="导入 ~/.dsh 的线路与模型")
    parser.add_argument("--import-dsh-dry-run", action="store_true", help="只列出会导入什么")
    parser.add_argument(
        "--import",
        dest="import_sources",
        action="append",
        choices=("all", "dsh", "codex"),
        help="把本地已有的线路配置拉进 router.json（all=DSH+Codex）",
    )
    parser.add_argument("--import-dry-run", action="store_true", help="只列出会导入什么")
    parser.add_argument(
        "--agent-target",
        default=None,
        help="导入后把这些线路追加到哪个 Agent（缺省不动 Agent，只进供应商池）",
    )
    parser.add_argument("--serve", action="store_true", help="启动总路由网关（前台常驻）")
    parser.add_argument(
        "--host",
        default=None,
        help="配合 --serve：临时改监听地址（不写 router.json，只在这个进程里生效）",
    )
    parser.add_argument(
        "--port",
        default=None,
        help="配合 --serve：临时改监听端口（0 = 自选空闲端口；不写 router.json）",
    )
    parser.add_argument(
        "--gateway-info",
        action="store_true",
        help="输出网关地址 / 密钥 / 各 Agent 片段（JSON）",
    )
    args = parser.parse_args()
    try:
        if args.agents_self_test:
            return agents_self_test()
        if args.agent_model_self_test:
            return agent_model_write_self_test()
        if args.models_self_test:
            return model_fetch_self_test()
        if args.gateway_listen_self_test:
            return gateway_listen_self_test()
        # --host / --port 是「本进程临时覆盖」，只有 --serve 会用到；
        # 单给它们等于没说清意图，直接拦下来，别让参数被悄悄忽略。
        if not args.serve and (args.host is not None or args.port is not None):
            raise RuntimeError("--host / --port 只跟 --serve 一起用（它们只改这次运行的监听地址）")
        # 一个只预览、一个真写盘：同时给就是没说清，直接拦下来，别让预览标志被忽略掉。
        if args.plan_agent_model and args.add_agent_model:
            raise RuntimeError("--plan-agent-model 只预览、--add-agent-model 真写盘：一次只能来一个")
        if args.agents:
            listing = export_agents(ensure_config())
            print(json.dumps(listing, ensure_ascii=False, indent=2) if args.export
                  else render_id_table(listing["clients"]))
            return 0
        if args.agent_models:
            rows = agent_model_rows(ensure_config(), args.agent_id)
            if args.export:
                print(json.dumps({
                    "version": 1,
                    "agent_id": args.agent_id,
                    "count": len(rows),
                    "models": rows,
                }, ensure_ascii=False, indent=2))
            else:
                print(render_model_table(rows))
            return 0
        if args.discover_agents:
            print(json.dumps(discover_external_agents(), ensure_ascii=False, indent=2))
            return 0
        config = ensure_config()
        if args.sync_agent:
            result = sync_external_agent(config, args.sync_client, args.sync_path, args.sync_agent_id)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.plan_agent_model or args.add_agent_model:
            options = {
                "client": args.sync_client,
                "path": args.sync_path,
                "agent_id": args.sync_agent_id,
                "provider_id": args.provider_id,
                "model": args.model,
                "provider_name": args.provider_name,
                "provider_url": args.provider_url,
                "provider_key": args.provider_key,
                "provider_wire": args.provider_wire,
            }
            result = (plan_agent_model(config, **options) if args.plan_agent_model
                      else add_model_to_external_agent(config, **options))
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.fetch_models:
            raw = sys.stdin.read()
            request = json.loads(raw or "{}")
            if not isinstance(request, dict):
                raise ValueError("模型同步输入必须是 JSON 对象")
            result = fetch_models(
                str(request.get("base_url") or ""),
                str(request.get("api_key") or ""),
                str(request.get("wire_api") or "chat_completions"),
            )
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result.get("ok") else 4
        if args.probe_all_connections:
            print(json.dumps(probe_all_connections(config), ensure_ascii=False))
            return 0
        if args.probe_models:
            print(json.dumps(probe_model_generation(config), ensure_ascii=False, indent=2))
            return 0
        if args.gateway_info:
            print(json.dumps(gateway_info(config), ensure_ascii=False, indent=2))
            return 0
        if args.serve:
            return serve_gateway(
                gateway_settings(config), args.host, args.port, args.agent_id or None
            )
        if args.import_sources:
            requested = [item for item in args.import_sources if item != "all"] or [
                "dsh",
                "codex",
            ]
            labels = {"dsh": "DSH", "codex": "Codex 配置"}
            added: list[str] = []
            updated: list[str] = []
            skipped: list[str] = []
            imported_ids: list[str] = []
            for source in requested:
                before = {
                    str(item.get("id"))
                    for item in config.get("providers") or []
                    if isinstance(item, dict)
                }
                if source == "dsh":
                    added.extend(import_dsh_config(config, dry_run=args.import_dry_run))
                else:
                    source_added, source_updated, source_skipped = import_codex_config(
                        config, dry_run=args.import_dry_run
                    )
                    added.extend(source_added)
                    updated.extend(source_updated)
                    skipped.extend(source_skipped)
                for item in config.get("providers") or []:
                    if not isinstance(item, dict):
                        continue
                    identifier = str(item.get("id"))
                    if identifier not in before and identifier not in imported_ids:
                        imported_ids.append(identifier)
            assigned: list[str] = []
            if args.agent_target and not args.import_dry_run:
                assigned = attach_providers_to_agent(
                    config, args.agent_target, imported_ids
                )
            payload = {
                "imported": len(added),
                "sources": [labels[item] for item in requested],
                "dry_run": bool(args.import_dry_run),
                "added": added,
                "updated": updated,
                "skipped": skipped,
                "assigned_to": (
                    {"agent": args.agent_target, "providers": assigned}
                    if assigned
                    else None
                ),
                "providers": [
                    {
                        "id": item.get("id"),
                        "name": item.get("name"),
                        "base_url": mask_url(item.get("base_url")),
                        "model": item.get("model"),
                        "has_key": bool(str(item.get("api_key") or "").strip()),
                    }
                    for item in config.get("providers") or []
                    if isinstance(item, dict)
                ],
                "config": str(CONFIG_PATH),
            }
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0
        if args.import_dsh or args.import_dsh_dry_run:
            added = import_dsh_config(config, dry_run=args.import_dsh_dry_run)
            payload = {
                "imported": len(added),
                "dry_run": bool(args.import_dsh_dry_run),
                "providers": added,
                "config": str(CONFIG_PATH),
            }
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0
        if args.provider:
            provider = next(
                (
                    item
                    for item in config.get("providers", [])
                    if isinstance(item, dict) and item.get("id") == args.provider
                ),
                None,
            )
            if not provider:
                print(f"没有找到供应商：{args.provider}", file=sys.stderr)
                return 3
            connection = next(
                (
                    item for item in config.get("connections", [])
                    if isinstance(item, dict) and item.get("id") == provider.get("connection_id")
                ),
                {},
            )
            provider = {**connection, **provider}
            prompt = sys.stdin.read().strip() or "只回复一句：连接正常。"
            try:
                answer = run_provider(provider, prompt)
            except Exception as exc:
                record_stat(provider, False, str(exc))
                print(str(exc), file=sys.stderr)
                return 1
            record_stat(provider, True)
            print(answer)
            return 0
        agent_id = resolve_agent_id(config, args.agent)
        providers = providers_for_agent(config, agent_id)
        if args.doctor:
            result = [
                {
                    "id": provider.get("id"),
                    "name": provider.get("name"),
                    "kind": provider.get("kind"),
                    "wire_api": (
                        "responses"
                        if is_responses_wire(provider)
                        else "chat_completions"
                    )
                    if str(provider.get("kind")) == "openai_compatible"
                    else None,
                    "model": provider.get("model"),
                    "base_url": mask_url(provider.get("base_url")),
                    "api_key_file": provider.get("api_key_file"),
                    "enabled": provider.get("enabled", True),
                }
                for provider in providers
            ]
            print(
                json.dumps(
                    {
                        "config": str(CONFIG_PATH),
                        "agent": agent_id,
                        "assistant_agent": str(config.get("assistant_agent") or ""),
                        "providers": result,
                        "agents": [
                            {
                                "id": agent.get("id"),
                                "name": agent.get("name"),
                                "assistant": agent.get("id") == agent_id,
                                "providers": len(agent.get("provider_ids") or []),
                            }
                            for agent in config.get("agents", [])
                            if isinstance(agent, dict)
                        ],
                    },
                    ensure_ascii=False,
                )
            )
            return 0
        prompt = sys.stdin.read().strip()
        if not prompt:
            print("路由输入为空。", file=sys.stderr)
            return 2
        if not providers:
            print(f"Agent「{agent_id}」没有已启用的供应商。", file=sys.stderr)
            return 3
        errors = []
        total = len(providers)
        deadline = time.time() + max(args.budget, 1.0)
        for index, provider in enumerate(providers, start=1):
            if time.time() > deadline:
                print(
                    f"[故障转移] 总预算 {args.budget:.0f}s 已用完，跳过剩下 "
                    f"{total - index + 1} 条线路。",
                    file=sys.stderr,
                )
                break
            name = str(provider.get("name") or provider.get("id") or "供应商")
            model = str(provider.get("model") or "")
            # 供应商名里往往已经带了模型（"Teamorouter · GPT-6 Astra"），别重复打印。
            label = name if not model or model.lower() in name.lower() else f"{name} · {model}"
            try:
                answer = run_provider(provider, prompt)
            except Exception as exc:
                errors.append(f"{label}: {exc}")
                record_stat(provider, False, str(exc))
                # 故障转移必须看得见：否则用户只知道"某条线路不灵"，不知道谁顶上了。
                print(f"[故障转移 {index}/{total}] {label} 失败：{exc}", file=sys.stderr)
                continue
            record_stat(provider, True)
            if total > 1 and index > 1:
                print(f"[故障转移] 第 {index}/{total} 条线路成功：{label}", file=sys.stderr)
            print(answer)
            return 0
        print("；".join(errors)[:1200], file=sys.stderr)
        # App 只把 stderr 的最后 400 个字符念给用户，人话放最后一句。
        first = errors[0] if errors else "没有可用线路"
        print(
            f"所有线路暂时都不可用（共 {total} 条）。第一条原因：{first[:140]}",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
