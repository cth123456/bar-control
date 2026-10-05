#!/usr/bin/env python3
"""Publish the 4230 default-Agent model pool to Codex's local picker catalog.

Codex is now routed through 4230, so the 4202-owned merged catalog is no longer
the right source for its model picker.  Keep native Codex entries and add the
models exposed by router.json's default Agent without copying credentials.
"""

from __future__ import annotations

import copy
import json
import os
import pathlib
import re
import shutil
import tempfile
from datetime import datetime, timezone


HOME = pathlib.Path.home()
ROUTER = HOME / "Library/Application Support/LocalSiriLLM/router.json"
NATIVE = HOME / ".codex/codex-router/merged-models.json"
OUTPUT = HOME / ".codex/ai-assistant-models.json"
CACHE = HOME / ".codex/models_cache.json"
CONFIG = HOME / ".codex/config.toml"


def read_json(path: pathlib.Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"不是 JSON 对象：{path}")
    return value


def exposed_codex_models(router: dict, native_slugs: set[str] | None = None) -> list[tuple[str, str]]:
    """Return the models the user explicitly assigned to Codex.

    ``agents.default.provider_ids`` is broader than Codex's picker: it also
    contains Jev's automatic decision route and may contain providers used by
    other clients.  ``client_assignments.codex`` is the narrow, user-facing
    selection list and is therefore the only source for extra Codex models.
    """
    providers = {
        str(row.get("id")): row
        for row in router.get("providers", [])
        if isinstance(row, dict) and row.get("id")
    }
    assignments = router.get("client_assignments")
    assigned = assignments.get("codex") if isinstance(assignments, dict) else []
    if not isinstance(assigned, list):
        return []

    by_model: dict[str, dict] = {}
    for provider in providers.values():
        model = str(provider.get("model") or "").strip()
        if model:
            by_model.setdefault(model.casefold(), provider)
        provider_id = str(provider.get("id") or "").strip()
        if provider_id:
            by_model.setdefault(provider_id.casefold(), provider)

    native_slugs = native_slugs or set()
    result: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(model: str, display: str, provider: dict | None = None) -> None:
        model = model.strip()
        if not model or model in seen:
            return
        seen.add(model)
        result.append((model, display or model))

    for raw_model in assigned:
        requested = str(raw_model or "").strip()
        if not requested:
            continue
        provider = by_model.get(requested.casefold())
        model = requested
        if provider:
            model = str(provider.get("model") or requested).strip()
        if not provider or not provider.get("enabled", True):
            provider = None
        if provider and str(provider.get("kind") or "").lower() == "dsh_bridge":
            continue
        add(model, str((provider or {}).get("name") or model), provider)
    default_ids = {
        str(value)
        for row in router.get("agents", [])
        if isinstance(row, dict) and row.get("id") == "default"
        for value in row.get("provider_ids", [])
    }
    for provider_id in default_ids:
        provider = providers.get(provider_id)
        if not provider or not provider.get("enabled", True):
            continue
        if str(provider.get("kind") or "").lower() == "dsh_bridge":
            continue
        source = str(provider.get("source") or "").lower()
        model = str(provider.get("model") or "").strip()
        if provider_id == "codex-router-jev-auto" or model == "jev/auto":
            add("jev/auto", "Jev 自动路由", provider)
            continue
        # 4202 的其它内部 provider 已由官方原生目录覆盖，不重复发布。
        if source == "dsh:codex-router":
            continue
        if not model:
            continue
        # 同名三方模型必须用 provider id 做别名，否则会与官方模型 slug 合并，
        # 点击后还会被误路由到官方模型。
        slug = provider_id if model in native_slugs else model
        add(slug, str(provider.get("name") or model), provider)
    return result


def publish() -> pathlib.Path:
    router = read_json(ROUTER)
    native = read_json(NATIVE)
    models = native.get("models")
    if not isinstance(models, list) or not models:
        raise ValueError("merged-models.json 没有可复用的 Codex 原生模型")
    by_slug = {str(row.get("slug")): row for row in models if isinstance(row, dict) and row.get("slug")}
    template = copy.deepcopy(by_slug.get("gpt-6-luna") or models[0])
    priority = max((int(row.get("priority", 0)) for row in models if isinstance(row, dict)), default=0) + 1
    native_slugs = set(by_slug)
    for slug, display in exposed_codex_models(router, native_slugs):
        if slug in by_slug:
            continue
        entry = copy.deepcopy(template)
        entry["slug"] = slug
        # 新增的三方线路不能继承模板的 code_mode_only：实测（2026-10-05 抓包）
        # 只要目录里带 tool_mode = "code_mode_only"，Codex 就会把 JS 代码工具
        # `exec`（custom 类型）发给模型，于是过程回复里每轮都出现
        # `const r = await tools.exec_command({...})` 这类 JavaScript；
        # 去掉该字段后，Codex 改发普通的 exec_command / write_stdin / apply_patch
        # 工具，工具调用照旧可用，但不再显示 JS 代码。
        entry.pop("tool_mode", None)
        route_label = display
        if slug.startswith("deepseek/"):
            route_label += " · 4202"
        elif slug.startswith("deepseek-"):
            route_label += " · 直连"
        entry["display_name"] = route_label
        entry["description"] = f"AI助手 default Agent · {route_label}"
        entry["priority"] = priority
        priority += 1
        by_slug[slug] = entry
    # 原生模型必须原样保留 Codex 原生目录里的 use_responses_lite。
    #
    # 实测（2026-10-05，本机 Codex 0.155.1 抓包）：
    #   use_responses_lite = false → 请求里带 7 个工具，其中包含 custom 类型
    #       的 JS `exec` 代码工具。于是每一轮过程回复都会显示
    #       `const r = await tools.exec_command({...}); text(r.output);` 这类代码，
    #       原生模型也一样（用户反馈的“任何模型回答都有代码”）。
    #   use_responses_lite = true  → 请求里不出现 tools，Codex 回到官方那种
    #       不显示 JS 的过程样式。
    # 所以这里只对我们新增的三方线路强制 false（Responses Lite 请求不带 tools，
    # DeepSeek 会退化成输出 DSML 文本，需要显式工具 schema）。
    native_lite = {
        str(row.get("slug")): row.get("use_responses_lite")
        for row in models
        if isinstance(row, dict) and row.get("slug")
    }
    for slug, entry in by_slug.items():
        if slug in native_lite:
            if native_lite[slug] is not None:
                entry["use_responses_lite"] = native_lite[slug]
        else:
            entry["use_responses_lite"] = False
    output = {**native, "models": list(by_slug.values())}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="ai-assistant-models-", suffix=".json", dir=OUTPUT.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(output, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, OUTPUT)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)

    # Codex's picker keeps a separate local cache.  Updating only the catalog
    # leaves the AI助手 card correct while the official client's menu silently
    # falls back to its old native-only list.  Merge the same visible rows into
    # that cache, preserving any metadata for rows we do not own.
    if CACHE.exists():
        try:
            cache = read_json(CACHE)
            cached = {
                str(row.get("slug")): row
                for row in cache.get("models", [])
                if isinstance(row, dict) and row.get("slug")
            }
            for row in output["models"]:
                if isinstance(row, dict) and row.get("visibility", "list") == "list":
                    cached[str(row["slug"])] = copy.deepcopy(row)
            cache_backup = CACHE.with_name(
                f"models_cache.json.before-ai-assistant-sync-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}"
            )
            shutil.copy2(CACHE, cache_backup)
            fd, cache_tmp = tempfile.mkstemp(prefix="models-cache-", suffix=".json", dir=CACHE.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    json.dump({**cache, "models": list(cached.values())}, handle, ensure_ascii=False, indent=2)
                    handle.write("\n")
                os.chmod(cache_tmp, 0o600)
                os.replace(cache_tmp, CACHE)
            finally:
                if os.path.exists(cache_tmp):
                    os.unlink(cache_tmp)
        except (OSError, ValueError, TypeError):
            # The catalog is the source of truth; a cache write failure must
            # not make router synchronization look like it failed.
            pass

    if CONFIG.exists():
        text = CONFIG.read_text(encoding="utf-8")
        backup = CONFIG.with_name(f"config.toml.ai-assistant-catalog-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}")
        shutil.copy2(CONFIG, backup)
        line = f'model_catalog_json = "{OUTPUT}"'
        if re.search(r"(?m)^model_catalog_json\s*=", text):
            text = re.sub(r"(?m)^model_catalog_json\s*=.*$", line, text)
        else:
            text = text.rstrip() + "\n" + line + "\n"
        CONFIG.write_text(text, encoding="utf-8")
    return OUTPUT


if __name__ == "__main__":
    path = publish()
    print(path)
