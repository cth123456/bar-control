#!/usr/bin/env python3
"""Read-only status bridge for Bar Control, Codex, and CC Switch."""

from __future__ import annotations

import argparse
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
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any


CODEX_DIR = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
CC_SWITCH_DB = Path.home() / ".cc-switch" / "cc-switch.db"
APP_DIR = Path.home() / "Library" / "Application Support" / "CodexTouchBar"
CC_SWITCH_USAGE_CACHE = APP_DIR / "cc-switch-usage-cache.json"
CC_SWITCH_USAGE_CACHE_SECONDS = 30
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
    url_match = re.search(r'url\s*:\s*["\']([^"\']+)', code)
    if not base_match or not url_match:
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

    url = substitute(url_match.group(1))
    base_parts = urllib.parse.urlparse(base_url)
    url_parts = urllib.parse.urlparse(url)
    if url_parts.scheme != "https" or (url_parts.hostname, url_parts.port) != (base_parts.hostname, base_parts.port):
        return None

    headers = {"Accept": "application/json", "User-Agent": "BarControl/1.0"}
    request_code = code.split("extractor", 1)[0]
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
    if isinstance(cached, dict) and now - float(cached.get("queried_at") or 0) < CC_SWITCH_USAGE_CACHE_SECONDS:
        return cached

    current = query_provider_usage(provider)
    if current:
        current["queried_at"] = now
        cache = cache if isinstance(cache, dict) else {}
        cache[provider_id] = current
        write_json(CC_SWITCH_USAGE_CACHE, cache)
        return current
    if isinstance(cached, dict) and now - float(cached.get("queried_at") or 0) < 300:
        return cached
    return None


def cc_switch_usage(db_path: Path = CC_SWITCH_DB, now: float | None = None) -> list[dict[str, Any]]:
    if not db_path.exists():
        return []
    current = datetime.fromtimestamp(now or time.time()).astimezone()
    day_start = current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    month_start = current.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp()
    try:
        connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.2)
        connection.row_factory = sqlite3.Row
        providers = {
            row["app_type"]: dict(row)
            for row in connection.execute(
                """
                SELECT id, app_type, name, category, limit_daily_usd, limit_monthly_usd,
                       settings_config, meta
                FROM providers
                WHERE is_current = 1
                """
            )
        }

        def totals(since: float) -> dict[str, dict[str, Any]]:
            rows = connection.execute(
                """
                SELECT app_type, COUNT(*) AS requests,
                       SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens,
                       SUM(CAST(total_cost_usd AS REAL)) AS cost,
                       MAX(created_at) AS latest_at
                FROM proxy_request_logs
                WHERE created_at >= ?
                GROUP BY app_type
                """,
                (int(since),),
            ).fetchall()
            return {row["app_type"]: dict(row) for row in rows}

        today = totals(day_start)
        month = totals(month_start)
        connection.close()
    except sqlite3.Error:
        return []

    labels = {
        "claude": "Claude",
        "codex": "Codex",
        "gemini": "Gemini",
        "grokbuild": "Grok",
        "opencode": "OpenCode",
        "hermes": "Hermes",
    }
    app_types = set(providers)
    result = []
    for app_type in app_types:
        provider = providers.get(app_type, {})
        # Built-in "official" providers use the signed-in subscription account.
        # Historical proxy logs must not keep the UI in API billing mode.
        if provider.get("category") == "official":
            continue
        daily = today.get(app_type, {})
        monthly = month.get(app_type, {})
        remote = cached_provider_usage(provider, now or time.time()) or {}
        remote_today_cost = safe_float(remote.get("remote_today_cost"))
        result.append(
            {
                "id": app_type,
                "label": labels.get(app_type, app_type.replace("-", " ").title()),
                "provider": provider.get("name") or "",
                "today_cost": round(float(remote_today_cost if remote_today_cost is not None else daily.get("cost") or 0), 6),
                "month_cost": round(float(monthly.get("cost") or 0), 6),
                "today_requests": int(daily.get("requests") or 0),
                "today_tokens": int(daily.get("tokens") or 0),
                "daily_limit": safe_float(provider.get("limit_daily_usd")),
                "monthly_limit": safe_float(provider.get("limit_monthly_usd")),
                "latest_at": float(daily.get("latest_at") or monthly.get("latest_at") or 0),
                "remaining_balance": safe_float(remote.get("remaining_balance")),
                "balance_unit": remote.get("balance_unit"),
            }
        )
    return sorted(result, key=lambda item: (item["latest_at"], item["today_cost"]), reverse=True)


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
        "platforms": cc_switch_usage(),
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
            "CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, category TEXT, limit_daily_usd TEXT, limit_monthly_usd TEXT, settings_config TEXT, meta TEXT, is_current INTEGER)"
        )
        connection.execute(
            "CREATE TABLE proxy_request_logs (app_type TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT, created_at INTEGER)"
        )
        connection.execute("INSERT INTO providers VALUES ('api-a', 'claude', 'API A', NULL, '10', '100', '{}', '{}', 1)")
        connection.execute("INSERT INTO proxy_request_logs VALUES ('claude', 100, 20, 5, 0, '2.5', 1786327200)")
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
