#!/usr/bin/env python3
"""Read-only status bridge for Bar Control, Codex, and CC Switch."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any


CODEX_DIR = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
CC_SWITCH_DB = Path.home() / ".cc-switch" / "cc-switch.db"
CODEX_AUTH_FILE = CODEX_DIR / "auth.json"
CC_SWITCH_CODEX_OAUTH_FILE = Path.home() / ".cc-switch" / "codex_oauth_auth.json"
APP_DIR = Path.home() / "Library" / "Application Support" / "CodexTouchBar"
CC_SWITCH_USAGE_CACHE = APP_DIR / "cc-switch-usage-cache.json"
CC_SWITCH_USAGE_CACHE_SECONDS = 30
AI_ACCOUNT_USAGE_CACHE = APP_DIR / "ai-account-usage-cache.json"
AI_ACCOUNT_USAGE_CACHE_SECONDS = 60
STATE_DB = CODEX_DIR / "state_5.sqlite"
RUNTIME_FILE = APP_DIR / "runtime.json"
CONFIG_FILE = APP_DIR / "config.json"
LOG_DIR = APP_DIR / "logs"
RENDER_DIR = APP_DIR / "render"
RENDERER = APP_DIR / "codex_touchbar_renderer"
WIDGET_UUIDS = (
    "48BB74EE-0C19-4E32-9968-824F975006CC",  # quota progress
    "E27B7738-1162-47CE-8EBE-A8931198EBC2",  # active sessions
)


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp, path)


def parse_time(value: str | None) -> float:
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def tail_json(path: Path, max_bytes: int = 512 * 1024) -> list[dict[str, Any]]:
    try:
        with path.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            start = max(0, size - max_bytes)
            handle.seek(start)
            if start:
                handle.readline()
            lines = handle.read().splitlines()
    except OSError:
        return []

    result: list[dict[str, Any]] = []
    for line in lines:
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(value, dict):
            result.append(value)
    return result


def recent_threads(limit: int = 24) -> list[dict[str, Any]]:
    if not STATE_DB.exists():
        return []
    try:
        connection = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=0.2)
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            """
            SELECT id, rollout_path, updated_at, cwd, preview
            FROM threads
            WHERE archived = 0 AND preview <> ''
            ORDER BY updated_at_ms DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        connection.close()
        return [dict(row) for row in rows]
    except sqlite3.Error:
        return []


def compact_reply(value: str, limit: int = 180) -> str:
    value = re.sub(r"!\[[^]]*]\([^)]+\)", "", value)
    value = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", value)
    value = re.sub(r"[`*_>#]+", "", value)
    return " ".join(value.split())[:limit]


def inspect_thread(thread: dict[str, Any]) -> dict[str, Any]:
    rollout = Path(thread["rollout_path"])
    try:
        file_size = rollout.stat().st_size
    except OSError:
        file_size = 0
    last_start = 0.0
    last_end = 0.0
    last_end_kind = ""
    latest_reply = ""
    newest_limits: tuple[float, dict[str, Any]] | None = None

    # Most turns have a boundary in the last 512 KB. Expand only for a long,
    # currently-running turn so old large sessions stay cheap to inspect.
    for budget in (512 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024, 16 * 1024 * 1024):
        last_start = 0.0
        last_end = 0.0
        last_end_kind = ""
        latest_reply = ""
        for item in tail_json(rollout, max_bytes=budget):
            if item.get("type") == "response_item":
                payload = item.get("payload") or {}
                if payload.get("type") == "message" and payload.get("role") == "assistant":
                    parts = [
                        part.get("text", "")
                        for part in payload.get("content") or []
                        if isinstance(part, dict) and part.get("type") == "output_text"
                    ]
                    candidate = compact_reply(" ".join(parts))
                    if candidate:
                        latest_reply = candidate
                continue
            if item.get("type") != "event_msg":
                continue
            payload = item.get("payload") or {}
            event_type = payload.get("type")
            timestamp = parse_time(item.get("timestamp"))
            if event_type == "task_started":
                last_start = max(last_start, timestamp)
            elif event_type in {"task_complete", "turn_aborted"}:
                if timestamp >= last_end:
                    last_end = timestamp
                    last_end_kind = event_type
            elif event_type == "token_count" and isinstance(payload.get("rate_limits"), dict):
                if newest_limits is None or timestamp > newest_limits[0]:
                    newest_limits = (timestamp, payload["rate_limits"])
        if last_start or last_end or file_size <= budget:
            break

    active = last_start > last_end and time.time() - last_start < 6 * 60 * 60
    return {
        **thread,
        "active": active,
        "last_start": last_start,
        "last_end": last_end,
        "last_end_kind": last_end_kind,
        "latest_reply": latest_reply,
        "limits": newest_limits,
    }


def process_command(pid: int) -> str:
    try:
        return subprocess.check_output(
            ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=1,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def module_task_running() -> bool:
    runtime = read_json(RUNTIME_FILE, {})
    pid = runtime.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return False
    command = process_command(pid)
    running = "codex" in command.lower() and "exec" in command.lower()
    if not running and runtime.get("status") == "running":
        runtime["status"] = "finished"
        runtime["finished_at"] = int(time.time())
        write_json(RUNTIME_FILE, runtime)
    return running


def format_window(minutes: Any) -> str:
    try:
        value = int(minutes)
    except (TypeError, ValueError):
        return "额度"
    if value % 10080 == 0:
        return f"{value // 10080 * 7}d"
    if value % 1440 == 0:
        return f"{value // 1440}d"
    if value % 60 == 0:
        return f"{value // 60}h"
    return f"{value}m"


def limit_windows(limits: dict[str, Any] | None) -> list[tuple[str, int]]:
    if not limits:
        return []
    windows: list[tuple[str, int]] = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        if not isinstance(window, dict) or window.get("used_percent") is None:
            continue
        try:
            remaining = max(0, min(100, round(100 - float(window["used_percent"]))))
        except (TypeError, ValueError):
            continue
        windows.append((format_window(window.get("window_minutes")), remaining))
    return windows


def format_limits(limits: dict[str, Any] | None) -> str:
    windows = limit_windows(limits)
    return " ".join(f"{name}{remaining}%" for name, remaining in windows) if windows else "额度–"


def progress_label(limits: dict[str, Any] | None, cells: int = 6) -> str:
    windows = limit_windows(limits)
    if not windows:
        return "额度 ▱▱▱▱▱▱"
    if len(windows) == 1:
        name, remaining = windows[0]
        filled = max(0, min(cells, round(remaining * cells / 100)))
        return f"{'▰' * filled}{'▱' * (cells - filled)} {remaining}%\n{name} 剩余额度"
    lines = []
    for name, remaining in windows[:2]:
        filled = max(0, min(cells, round(remaining * cells / 100)))
        lines.append(f"{name} {'▰' * filled}{'▱' * (cells - filled)} {remaining}%")
    return "\n".join(lines)


def quota_widget_payload(limits: dict[str, Any] | None) -> dict[str, Any]:
    by_label: dict[str, dict[str, Any]] = {}
    if isinstance(limits, dict):
        for key in ("primary", "secondary"):
            window = limits.get(key)
            if not isinstance(window, dict):
                continue
            label = format_window(window.get("window_minutes"))
            used = window.get("used_percent")
            try:
                used_value = max(0.0, min(100.0, float(used))) if used is not None else None
            except (TypeError, ValueError):
                used_value = None
            reset = window.get("resets_at")
            try:
                reset_value = float(reset) if reset is not None else None
            except (TypeError, ValueError):
                reset_value = None
            by_label[label] = {"label": label, "used": used_value, "reset": reset_value}

    windows = []
    for label in ("5h", "7d"):
        windows.append(by_label.pop(label, {"label": label, "used": None, "reset": None}))
    for item in by_label.values():
        if len(windows) >= 2:
            break
        windows.append(item)
    return {"windows": windows[:2]}


def safe_float(value: Any) -> float | None:
    try:
        return float(value) if value not in (None, "") else None
    except (TypeError, ValueError):
        return None


def extract_provider_usage(response: Any) -> dict[str, Any] | None:
    if not isinstance(response, dict):
        return None
    balance_infos = response.get("balance_infos")
    if isinstance(balance_infos, list):
        first = next((item for item in balance_infos if isinstance(item, dict)), None)
        if first:
            remaining = safe_float(first.get("total_balance"))
            if remaining is not None:
                return {
                    "remaining_balance": remaining,
                    "balance_unit": str(first.get("currency") or "CNY")[:8],
                    "remote_today_cost": None,
                }
    quota = response.get("quota") if isinstance(response.get("quota"), dict) else {}
    remaining = safe_float(response.get("remaining"))
    if remaining is None:
        remaining = safe_float(quota.get("remaining"))
    if remaining is None:
        remaining = safe_float(response.get("balance"))
    if remaining is None:
        return None

    usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}
    today = usage.get("today") if isinstance(usage.get("today"), dict) else {}
    today_cost = safe_float(today.get("actual_cost"))
    if today_cost is None:
        today_cost = safe_float(today.get("cost"))
    unit = response.get("unit") or quota.get("unit") or "USD"
    return {
        "remaining_balance": remaining,
        "balance_unit": str(unit)[:8],
        "remote_today_cost": today_cost,
    }


def query_provider_usage(provider: dict[str, Any]) -> dict[str, Any] | None:
    try:
        settings = json.loads(provider.get("settings_config") or "{}")
        metadata = json.loads(provider.get("meta") or "{}")
    except (TypeError, json.JSONDecodeError):
        return None
    script = metadata.get("usage_script")
    if not isinstance(script, dict) or not script.get("enabled"):
        return None
    code = script.get("code")
    config = settings.get("config")
    auth = settings.get("auth")
    if not isinstance(code, str) or not isinstance(config, str) or not isinstance(auth, dict):
        return None

    base_match = re.search(r'^base_url\s*=\s*["\']([^"\']+)', config, re.MULTILINE)
    if not base_match:
        return None
    base_url = base_match.group(1).rstrip("/")
    api_key = next(
        (
            auth.get(name)
            for name in ("OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "GEMINI_API_KEY")
            if isinstance(auth.get(name), str) and auth.get(name)
        ),
        None,
    )
    if not api_key:
        return None

    replacements = {"{{baseUrl}}": base_url, "{{apiKey}}": api_key}

    def substitute(value: str) -> str:
        for placeholder, replacement in replacements.items():
            value = value.replace(placeholder, replacement)
        return value

    if script.get("templateType") == "balance" and "api.deepseek.com" in base_url.lower():
        url = "https://api.deepseek.com/user/balance"
        request_code = ""
        native_balance = True
    else:
        url_match = re.search(r'url\s*:\s*["\']([^"\']+)', code)
        if not url_match:
            return None
        url = substitute(url_match.group(1))
        request_code = code.split("extractor", 1)[0]
        native_balance = False
    base_parts = urllib.parse.urlparse(base_url)
    url_parts = urllib.parse.urlparse(url)
    if url_parts.scheme != "https" or (url_parts.hostname, url_parts.port) != (base_parts.hostname, base_parts.port):
        return None

    headers = {"Accept": "application/json", "User-Agent": "BarControl/1.0"}
    if native_balance:
        headers["Authorization"] = f"Bearer {api_key}"
    for name, value in re.findall(r'["\']([^"\']+)["\']\s*:\s*["\']([^"\']*)["\']', request_code):
        if name.lower() not in {"url", "method"}:
            headers[name] = substitute(value)
    try:
        request = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(request, timeout=min(10, int(script.get("timeout") or 10))) as response:
            return extract_provider_usage(json.load(response))
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def cached_provider_usage(provider: dict[str, Any], now: float) -> dict[str, Any] | None:
    provider_id = str(provider.get("id") or "")
    if not provider_id:
        return None
    cache = read_json(CC_SWITCH_USAGE_CACHE, {})
    cached = cache.get(provider_id) if isinstance(cache, dict) else None
    try:
        metadata = json.loads(provider.get("meta") or "{}")
    except (TypeError, json.JSONDecodeError):
        metadata = {}
    script = metadata.get("usage_script") if isinstance(metadata, dict) else None
    interval_minutes = safe_float(script.get("autoQueryInterval")) if isinstance(script, dict) else None
    cache_seconds = max(60, int((interval_minutes or 5) * 60))
    if isinstance(cached, dict) and now - float(cached.get("queried_at") or 0) < cache_seconds:
        return cached

    current = query_provider_usage(provider)
    if current:
        history = cached.get("history") if isinstance(cached, dict) else []
        history = history if isinstance(history, list) else []
        balance = safe_float(current.get("remaining_balance"))
        last = history[-1] if history and isinstance(history[-1], dict) else {}
        if balance is not None and (
            safe_float(last.get("primary")) != balance
            or now - float(last.get("timestamp") or 0) >= cache_seconds
        ):
            history.append({"timestamp": now, "primary": balance, "secondary": None})
        current["history"] = [
            point for point in history[-96:]
            if isinstance(point, dict) and now - float(point.get("timestamp") or 0) <= 7 * 86_400
        ]
        current["queried_at"] = now
        cache = cache if isinstance(cache, dict) else {}
        cache[provider_id] = current
        write_json(CC_SWITCH_USAGE_CACHE, cache)
        return current
    if isinstance(cached, dict) and now - float(cached.get("queried_at") or 0) < max(600, cache_seconds * 2):
        return cached
    return None


def decode_jwt_claims(token: Any) -> dict[str, Any]:
    if not isinstance(token, str):
        return {}
    parts = token.split(".")
    if len(parts) < 2:
        return {}
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        value = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
        return value if isinstance(value, dict) else {}
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return {}


def live_codex_auth() -> dict[str, Any]:
    value = read_json(CODEX_AUTH_FILE, {})
    tokens = value.get("tokens") if isinstance(value, dict) else None
    if not isinstance(tokens, dict):
        return {}
    claims = decode_jwt_claims(tokens.get("id_token"))
    openai_auth = claims.get("https://api.openai.com/auth")
    openai_auth = openai_auth if isinstance(openai_auth, dict) else {}
    account_id = tokens.get("account_id") or claims.get("chatgpt_account_id") or openai_auth.get("chatgpt_account_id")
    if not isinstance(account_id, str) or not account_id:
        return {}
    try:
        modified_at = CODEX_AUTH_FILE.stat().st_mtime
    except OSError:
        modified_at = 0.0
    return {
        "account_id": account_id,
        "email": claims.get("email") if isinstance(claims.get("email"), str) else None,
        "access_token": tokens.get("access_token") if isinstance(tokens.get("access_token"), str) else None,
        "modified_at": modified_at,
    }


def managed_codex_accounts() -> list[dict[str, Any]]:
    store = read_json(CC_SWITCH_CODEX_OAUTH_FILE, {})
    raw_accounts = store.get("accounts") if isinstance(store, dict) else None
    if not isinstance(raw_accounts, dict):
        return []
    result = []
    for account_id, value in raw_accounts.items():
        if not isinstance(account_id, str) or not isinstance(value, dict):
            continue
        email = value.get("email")
        result.append(
            {
                "account_id": account_id,
                "email": email if isinstance(email, str) else None,
                "authenticated_at": float(value.get("authenticated_at") or 0),
            }
        )
    return result


def normalize_codex_quota_response(response: Any) -> dict[str, Any] | None:
    rate_limit = response.get("rate_limit") if isinstance(response, dict) else None
    if not isinstance(rate_limit, dict):
        return None
    windows = []
    for key in ("primary_window", "secondary_window"):
        window = rate_limit.get(key)
        if not isinstance(window, dict):
            continue
        used = safe_float(window.get("used_percent"))
        if used is not None:
            windows.append(max(0.0, min(100.0, 100.0 - used)))
    if not windows:
        return None
    return {
        "remaining_percent": windows[0],
        "secondary_remaining_percent": windows[1] if len(windows) > 1 else None,
    }


def normalize_rollout_quota(limits: Any) -> dict[str, Any] | None:
    if not isinstance(limits, dict):
        return None
    windows = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        used = safe_float(window.get("used_percent")) if isinstance(window, dict) else None
        if used is not None:
            windows.append(max(0.0, min(100.0, 100.0 - used)))
    if not windows:
        return None
    return {
        "remaining_percent": windows[0],
        "secondary_remaining_percent": windows[1] if len(windows) > 1 else None,
    }


def cached_account_quota(account_id: str) -> dict[str, Any]:
    cache = read_json(AI_ACCOUNT_USAGE_CACHE, {})
    accounts = cache.get("accounts") if isinstance(cache, dict) else None
    value = accounts.get(account_id) if isinstance(accounts, dict) else None
    return value if isinstance(value, dict) else {}


def record_account_quota(account_id: str, quota: dict[str, Any], now: float) -> dict[str, Any]:
    cache = read_json(AI_ACCOUNT_USAGE_CACHE, {})
    cache = cache if isinstance(cache, dict) else {}
    accounts = cache.get("accounts")
    accounts = accounts if isinstance(accounts, dict) else {}
    previous = accounts.get(account_id)
    previous = previous if isinstance(previous, dict) else {}
    history = previous.get("history")
    history = history if isinstance(history, list) else []
    primary = safe_float(quota.get("remaining_percent"))
    secondary = safe_float(quota.get("secondary_remaining_percent"))
    last = history[-1] if history and isinstance(history[-1], dict) else {}
    if primary is not None and (
        safe_float(last.get("primary")) != primary
        or safe_float(last.get("secondary")) != secondary
        or now - float(last.get("timestamp") or 0) >= 900
    ):
        history.append({"timestamp": now, "primary": primary, "secondary": secondary})
    saved = {
        "queried_at": now,
        "remaining_percent": primary,
        "secondary_remaining_percent": secondary,
        "history": [
            point for point in history[-96:]
            if isinstance(point, dict) and now - float(point.get("timestamp") or 0) <= 7 * 86_400
        ],
    }
    accounts[account_id] = saved
    cache["accounts"] = accounts
    write_json(AI_ACCOUNT_USAGE_CACHE, cache)
    return saved


def active_codex_quota(live_auth: dict[str, Any], fallback_limits: Any, now: float) -> dict[str, Any]:
    account_id = live_auth.get("account_id")
    if not isinstance(account_id, str):
        return {}
    cached = cached_account_quota(account_id)
    if now - float(cached.get("queried_at") or 0) < AI_ACCOUNT_USAGE_CACHE_SECONDS:
        return cached
    token = live_auth.get("access_token")
    if isinstance(token, str) and token:
        request = urllib.request.Request(
            "https://chatgpt.com/backend-api/wham/usage",
            headers={
                "Authorization": f"Bearer {token}",
                "ChatGPT-Account-Id": account_id,
                "User-Agent": "codex-cli",
                "Accept": "application/json",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                raw = response.read(128 * 1024 + 1)
            if len(raw) <= 128 * 1024:
                quota = normalize_codex_quota_response(json.loads(raw))
                if quota:
                    return record_account_quota(account_id, quota, now)
        except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError):
            pass
    fallback = normalize_rollout_quota(fallback_limits)
    return record_account_quota(account_id, fallback, now) if fallback else cached


def provider_auth_binding(provider: dict[str, Any]) -> str | None:
    try:
        meta = json.loads(provider.get("meta") or "{}")
    except (TypeError, json.JSONDecodeError):
        return None
    binding = meta.get("authBinding") if isinstance(meta, dict) else None
    if not isinstance(binding, dict) or binding.get("source") != "managed_account" or binding.get("authProvider") != "codex_oauth":
        return None
    account_id = binding.get("accountId")
    return account_id if isinstance(account_id, str) and account_id else None


def usage_account_stats(value: dict[str, Any]) -> tuple[float | None, float | None]:
    cacheable = int(value.get("input_tokens") or 0) + int(value.get("cache_creation_tokens") or 0) + int(value.get("cache_read_tokens") or 0)
    cache_hit = 100.0 * int(value.get("cache_read_tokens") or 0) / cacheable if cacheable > 0 else None
    requests = int(value.get("requests") or 0)
    success = 100.0 * int(value.get("successes") or 0) / requests if requests > 0 else None
    return cache_hit, success


def account_label(email: Any, account_id: str) -> str:
    return email if isinstance(email, str) and email else "ChatGPT · " + account_id[-4:]


def cc_switch_snapshot(
    db_path: Path = CC_SWITCH_DB,
    now: float | None = None,
    limits: Any = None,
) -> dict[str, list[dict[str, Any]]]:
    timestamp = now or time.time()
    current = datetime.fromtimestamp(timestamp).astimezone()
    day_start = current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    month_start = current.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp()
    history_start = day_start - 6 * 86_400
    live_auth = live_codex_auth() if db_path == CC_SWITCH_DB else {}
    managed_accounts = managed_codex_accounts() if db_path == CC_SWITCH_DB else []
    active_quota = active_codex_quota(live_auth, limits, timestamp) if live_auth else {}

    providers: list[dict[str, Any]] = []
    today: dict[tuple[str, str], dict[str, Any]] = {}
    month: dict[tuple[str, str], dict[str, Any]] = {}
    stats: dict[tuple[str, str], dict[str, Any]] = {}
    histories: dict[tuple[str, str], list[dict[str, Any]]] = {}
    latest_models: dict[tuple[str, str], str] = {}
    if db_path.exists():
        try:
            connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.2)
            connection.row_factory = sqlite3.Row
            providers = [dict(row) for row in connection.execute(
                """
                SELECT id, app_type, name, category, is_current, limit_daily_usd,
                       limit_monthly_usd, settings_config, meta, sort_index, created_at
                FROM providers ORDER BY app_type, is_current DESC,
                     COALESCE(sort_index, 9223372036854775807), created_at, name
                """
            )]

            def totals(since: float) -> dict[tuple[str, str], dict[str, Any]]:
                rows = connection.execute(
                    """
                    SELECT app_type, provider_id, COUNT(*) AS requests,
                           SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens,
                           SUM(CAST(total_cost_usd AS REAL)) AS cost, MAX(created_at) AS latest_at
                    FROM proxy_request_logs WHERE created_at >= ? GROUP BY app_type, provider_id
                    """,
                    (int(since),),
                ).fetchall()
                return {(row["app_type"], row["provider_id"]): dict(row) for row in rows}

            today = totals(day_start)
            month = totals(month_start)
            stats = {
                (row["app_type"], row["provider_id"]): dict(row)
                for row in connection.execute(
                    """
                    SELECT app_type, provider_id, COUNT(*) AS requests,
                           SUM(CASE WHEN status_code >= 200 AND status_code < 400 THEN 1 ELSE 0 END) AS successes,
                           SUM(input_tokens) AS input_tokens, SUM(cache_read_tokens) AS cache_read_tokens,
                           SUM(cache_creation_tokens) AS cache_creation_tokens
                    FROM proxy_request_logs WHERE created_at >= ? GROUP BY app_type, provider_id
                    """,
                    (int(month_start),),
                )
            }
            for row in connection.execute(
                """
                SELECT app_type, provider_id, strftime('%Y-%m-%d', created_at, 'unixepoch', 'localtime') AS day,
                       COUNT(*) AS requests,
                       SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens,
                       SUM(CAST(total_cost_usd AS REAL)) AS cost
                FROM proxy_request_logs WHERE created_at >= ?
                GROUP BY app_type, provider_id, day ORDER BY day
                """,
                (int(history_start),),
            ):
                histories.setdefault((row["app_type"], row["provider_id"]), []).append(dict(row))
            for row in connection.execute(
                """
                SELECT logs.app_type, logs.provider_id, logs.model
                FROM proxy_request_logs AS logs JOIN (
                    SELECT app_type, provider_id, MAX(created_at) AS latest_at
                    FROM proxy_request_logs GROUP BY app_type, provider_id
                ) AS latest ON logs.app_type = latest.app_type
                    AND logs.provider_id = latest.provider_id AND logs.created_at = latest.latest_at
                """
            ):
                latest_models[(row["app_type"], row["provider_id"])] = row["model"] or ""
            connection.close()
        except sqlite3.Error:
            providers = []

    labels = {
        "claude": "Claude", "claude-desktop": "Claude Desktop", "codex": "Codex",
        "gemini": "Gemini", "grokbuild": "Grok", "opencode": "OpenCode",
        "openclaw": "OpenClaw", "hermes": "Hermes", "pi": "Pi",
    }
    visible_apps = {row["app_type"] for row in providers if row.get("is_current")}
    visible_apps.update(app_type for app_type, _ in month)
    if managed_accounts or live_auth:
        visible_apps.add("codex")

    def history_points(key: tuple[str, str]) -> tuple[list[dict[str, Any]], str, str]:
        rows = histories.get(key, [])
        use_cost = any(float(row.get("cost") or 0) > 0 for row in rows)
        points = []
        for row in rows:
            try:
                point_time = datetime.fromisoformat(str(row["day"])).astimezone().timestamp()
            except (ValueError, TypeError):
                continue
            points.append({
                "timestamp": point_time,
                "primary": float(row.get("cost") or 0) if use_cost else float(row.get("tokens") or 0),
                "secondary": None,
            })
        return points, "USD" if use_cost else "tokens", "7日费用" if use_cost else "7日 Token"

    bound_providers = {
        binding: provider for provider in providers
        if provider.get("app_type") == "codex" and (binding := provider_auth_binding(provider))
    }
    managed_ids = {item["account_id"] for item in managed_accounts}
    if live_auth and live_auth["account_id"] not in managed_ids:
        managed_accounts.append({
            "account_id": live_auth["account_id"],
            "email": live_auth.get("email"),
            "authenticated_at": float(live_auth.get("modified_at") or 0),
        })

    accounts = []
    legacy = []
    for managed in managed_accounts:
        account_id = managed["account_id"]
        is_current = live_auth.get("account_id") == account_id
        quota = active_quota if is_current and active_quota else cached_account_quota(account_id)
        aggregate_key = ("codex", "_codex_session")
        daily = today.get(aggregate_key, {}) if is_current else {}
        monthly = month.get(aggregate_key, {}) if is_current else {}
        cache_hit, success = usage_account_stats(stats.get(aggregate_key, {}) if is_current else {})
        activity_history, chart_unit, chart_title = history_points(aggregate_key) if is_current else ([], "percent", "额度趋势")
        quota_history = quota.get("history") if isinstance(quota.get("history"), list) else []
        history = activity_history if len(activity_history) >= 2 else quota_history
        if history is quota_history:
            chart_unit, chart_title = "percent", "额度趋势"
        provider = bound_providers.get(account_id)
        accounts.append({
            "key": f"codex:oauth:{account_id}", "client_id": "codex", "client_label": "Codex",
            "account_label": account_label(managed.get("email"), account_id),
            "provider_label": (provider or {}).get("name") or "OpenAI Official",
            "is_current": is_current, "is_official": True, "metric_kind": "subscription",
            "remaining_balance": None, "balance_unit": None,
            "remaining_percent": safe_float(quota.get("remaining_percent")),
            "secondary_remaining_percent": safe_float(quota.get("secondary_remaining_percent")),
            "today_cost": round(float(daily.get("cost") or 0), 6),
            "month_cost": round(float(monthly.get("cost") or 0), 6),
            "today_requests": int(daily.get("requests") or 0), "today_tokens": int(daily.get("tokens") or 0),
            "cache_hit_percent": cache_hit, "success_percent": success,
            "model_label": latest_models.get(aggregate_key, "") if is_current else "",
            "metrics_scope": "Codex 会话总计" if is_current else "账户额度",
            "chart_title": chart_title, "chart_unit": chart_unit,
            "latest_at": float(quota.get("queried_at") or managed.get("authenticated_at") or 0),
            "history": history,
        })

    for provider in providers:
        app_type = provider.get("app_type") or ""
        provider_id = provider.get("id") or ""
        if app_type not in visible_apps or not provider_id:
            continue
        is_official = provider.get("category") == "official"
        if app_type == "codex" and is_official and live_auth:
            continue
        key = (app_type, provider_id)
        if is_official and not provider.get("is_current") and key not in month:
            continue
        daily = today.get(key, {})
        monthly = month.get(key, {})
        remote = {} if is_official else (cached_provider_usage(provider, timestamp) or {})
        remote_today_cost = safe_float(remote.get("remote_today_cost"))
        today_cost = float(remote_today_cost if remote_today_cost is not None else daily.get("cost") or 0)
        month_cost = float(monthly.get("cost") or 0)
        daily_limit = safe_float(provider.get("limit_daily_usd"))
        monthly_limit = safe_float(provider.get("limit_monthly_usd"))
        budget = monthly_limit if (daily_limit or 0) <= 0 and (monthly_limit or 0) > 0 else daily_limit
        spent = month_cost if budget == monthly_limit and budget is not None else today_cost
        remaining_percent = max(0.0, min(100.0, 100.0 - spent / budget * 100.0)) if budget and budget > 0 else None
        points = remote.get("history") if isinstance(remote.get("history"), list) else []
        if points:
            chart_unit = remote.get("balance_unit") or "USD"
            chart_title = "余额趋势"
        else:
            points, chart_unit, chart_title = history_points(key)
        cache_hit, success = usage_account_stats(stats.get(key, {}))
        remaining_balance = safe_float(remote.get("remaining_balance"))
        client_label = labels.get(app_type, app_type.replace("-", " ").title())
        account = {
            "key": f"{app_type}:provider:{provider_id}", "client_id": app_type,
            "client_label": client_label, "account_label": provider.get("name") or client_label,
            "provider_label": "官方账户" if is_official else "API",
            "is_current": bool(provider.get("is_current")), "is_official": is_official,
            "metric_kind": "subscription" if is_official else ("balance" if remaining_balance is not None else "cost"),
            "remaining_balance": remaining_balance, "balance_unit": remote.get("balance_unit") or "USD",
            "remaining_percent": remaining_percent, "secondary_remaining_percent": None,
            "today_cost": round(today_cost, 6), "month_cost": round(month_cost, 6),
            "today_requests": int(daily.get("requests") or 0), "today_tokens": int(daily.get("tokens") or 0),
            "cache_hit_percent": cache_hit, "success_percent": success,
            "model_label": latest_models.get(key, ""), "metrics_scope": provider.get("name") or client_label,
            "chart_title": chart_title, "chart_unit": chart_unit,
            "latest_at": float(remote.get("queried_at") or daily.get("latest_at") or monthly.get("latest_at") or 0),
            "history": points,
        }
        accounts.append(account)
        if not is_official:
            legacy.append({
                "id": app_type, "label": client_label, "provider": provider.get("name") or "",
                "today_cost": round(today_cost, 6), "month_cost": round(month_cost, 6),
                "today_requests": int(daily.get("requests") or 0), "today_tokens": int(daily.get("tokens") or 0),
                "daily_limit": daily_limit, "monthly_limit": monthly_limit,
                "latest_at": account["latest_at"], "remaining_balance": remaining_balance,
                "balance_unit": remote.get("balance_unit"),
            })

    order = {name: index for index, name in enumerate(labels)}
    accounts.sort(key=lambda item: order.get(item["client_id"], 99))
    return {"platforms": legacy, "accounts": accounts}


def cc_switch_usage(db_path: Path = CC_SWITCH_DB, now: float | None = None) -> list[dict[str, Any]]:
    return cc_switch_snapshot(db_path=db_path, now=now)["platforms"]


def thread_state(thread: dict[str, Any]) -> str:
    if thread.get("active"):
        return "running"
    if thread.get("last_end_kind") == "turn_aborted":
        return "aborted"
    if thread.get("last_end_kind") == "task_complete":
        return "completed"
    return "idle"


def session_widget_payload() -> dict[str, Any]:
    sessions = []
    for thread in recent_threads(limit=24):
        inspected = inspect_thread(thread)
        if not inspected["active"]:
            continue
        reply = inspected["latest_reply"] or compact_reply(str(thread.get("preview") or "正在处理"))
        sessions.append({"title": reply, "state": "running"})
    return {"sessions": sessions[:5]}


def open_active_session() -> int:
    thread = next((item for item in recent_threads() if inspect_thread(item)["active"]), None)
    if not thread:
        return 1
    thread_id = str(thread.get("id") or "")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", thread_id):
        return 2
    return subprocess.run(["/usr/bin/open", f"codex://threads/{thread_id}"], check=False).returncode


def snapshot() -> dict[str, Any]:
    inspected = [inspect_thread(thread) for thread in recent_threads()]
    active = [thread for thread in inspected if thread["active"]]
    newest_limits: tuple[float, dict[str, Any]] | None = None
    newest_end: tuple[float, str] = (0.0, "")
    for thread in inspected:
        limits = thread.get("limits")
        if limits and (newest_limits is None or limits[0] > newest_limits[0]):
            newest_limits = limits
        if thread["last_end"] > newest_end[0]:
            newest_end = (thread["last_end"], thread["last_end_kind"])

    limit_text = format_limits(newest_limits[1] if newest_limits else None)
    if active:
        label = f"●{len(active)} {limit_text}"
        state = "running"
    elif newest_end[0] and time.time() - newest_end[0] < 120:
        failed = newest_end[1] == "turn_aborted"
        label = f"{'✕' if failed else '✓'} {'中止' if failed else '完成'} {limit_text}"
        state = "aborted" if failed else "completed"
    else:
        label = f"○ 空闲 {limit_text}"
        state = "idle"

    usage = cc_switch_snapshot(limits=newest_limits[1] if newest_limits else None)
    return {
        "label": label,
        "state": state,
        "active_count": len(active),
        "active_threads": [
            {
                "id": item.get("id"),
                "title": (
                    item.get("latest_reply")
                    or compact_reply(str(item.get("preview") or "正在处理"))
                )[:180],
                "cwd": item.get("cwd", ""),
            }
            for item in active
        ],
        "limits": newest_limits[1] if newest_limits else None,
        "platforms": usage["platforms"],
        "accounts": usage["accounts"],
    }


def self_test() -> None:
    assert format_window(300) == "5h"
    assert format_window(10080) == "7d"
    assert format_limits({"primary": {"used_percent": 29, "window_minutes": 10080}}) == "7d71%"
    assert progress_label({"primary": {"used_percent": 50, "window_minutes": 300}}) == "▰▰▰▱▱▱ 50%\n5h 剩余额度"
    assert quota_widget_payload({"primary": {"used_percent": 40, "window_minutes": 300, "resets_at": 1234}})["windows"][0] == {
        "label": "5h",
        "used": 40.0,
        "reset": 1234.0,
    }
    assert compact_reply("**完成** [详情](https://example.com)\n下一步") == "完成 详情 下一步"
    with tempfile.TemporaryDirectory() as directory:
        usage_db = Path(directory) / "cc-switch.db"
        connection = sqlite3.connect(usage_db)
        connection.execute(
            "CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, category TEXT, limit_daily_usd TEXT, limit_monthly_usd TEXT, settings_config TEXT, meta TEXT, is_current INTEGER, sort_index INTEGER, created_at INTEGER)"
        )
        connection.execute(
            "CREATE TABLE proxy_request_logs (app_type TEXT, provider_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT, status_code INTEGER, created_at INTEGER)"
        )
        connection.execute("INSERT INTO providers VALUES ('api-a', 'claude', 'API A', NULL, '10', '100', '{}', '{}', 1, 0, 1786327000)")
        connection.execute("INSERT INTO proxy_request_logs VALUES ('claude', 'api-a', 'claude-test', 100, 20, 5, 0, '2.5', 200, 1786327200)")
        connection.commit()
        connection.close()
        usage = cc_switch_usage(usage_db, now=1786330800)
        assert usage[0]["label"] == "Claude"
        assert usage[0]["today_cost"] == 2.5
        assert usage[0]["daily_limit"] == 10.0
        assert usage[0]["remaining_balance"] is None
        assert extract_provider_usage({"balance": 17.03, "unit": "USD", "usage": {"today": {"actual_cost": 3.2}}}) == {
            "remaining_balance": 17.03,
            "balance_unit": "USD",
            "remote_today_cost": 3.2,
        }
        assert extract_provider_usage({"balance_infos": [{"currency": "CNY", "total_balance": "6.21"}]}) == {
            "remaining_balance": 6.21,
            "balance_unit": "CNY",
            "remote_today_cost": None,
        }
        connection = sqlite3.connect(usage_db)
        connection.execute("UPDATE providers SET category = 'official'")
        connection.commit()
        connection.close()
        assert cc_switch_usage(usage_db, now=1786330800) == []

        rollout = Path(directory) / "rollout.jsonl"
        rollout.write_text(
            "\n".join(
                [
                    json.dumps({"timestamp": "2026-08-09T00:00:00Z", "type": "event_msg", "payload": {"type": "task_started"}}),
                    json.dumps({"timestamp": "2026-08-09T00:00:30Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "正在整理最新结果"}]}}),
                    json.dumps({"timestamp": "2026-08-09T00:01:00Z", "type": "event_msg", "payload": {"type": "task_complete"}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        result = inspect_thread({"id": "test", "rollout_path": str(rollout), "cwd": directory, "preview": "test"})
        assert result["active"] is False
        assert result["last_end_kind"] == "task_complete"
        assert result["latest_reply"] == "正在整理最新结果"


def main() -> int:
    parser = argparse.ArgumentParser(description="Bar Control status bridge")
    subparsers = parser.add_subparsers(dest="command", required=True)
    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--json", action="store_true")
    subparsers.add_parser("self-test")
    args = parser.parse_args()

    if args.command == "status":
        value = snapshot()
        print(json.dumps(value, ensure_ascii=False) if args.json else value["label"])
        return 0
    self_test()
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
