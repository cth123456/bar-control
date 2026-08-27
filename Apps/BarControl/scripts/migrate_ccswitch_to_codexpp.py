#!/usr/bin/env python3
"""One-time, idempotent migration from CC Switch to Codex++ and Bar Control.

Secrets stay in local application-support/config files. Nothing is printed or
written into the repository except this migration logic.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import time
from pathlib import Path


HOME = Path.home()
CC_DIR = HOME / ".cc-switch"
CC_DB = CC_DIR / "cc-switch.db"
CC_SETTINGS = CC_DIR / "settings.json"
CODEXPP_DIR = HOME / ".codex-session-delete"
CODEXPP_SETTINGS = CODEXPP_DIR / "settings.json"
BAR_DIR = HOME / "Library" / "Application Support" / "BarControl"
BAR_DB = BAR_DIR / "provider-store.db"
BAR_SETTINGS = BAR_DIR / "provider-settings.json"
BAR_MAPPING = BAR_DIR / "codexpp-provider-map.json"


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json_atomic(path: Path, value, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(temp, mode)
    os.replace(temp, path)


def sqlite_backup(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_connection = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    destination_connection = sqlite3.connect(destination)
    try:
        source_connection.backup(destination_connection)
    finally:
        destination_connection.close()
        source_connection.close()
    os.chmod(destination, 0o600)


def base_url(config: str) -> str:
    match = re.search(r'^base_url\s*=\s*["\']([^"\']+)', config, re.MULTILINE)
    return match.group(1).rstrip("/") if match else ""


def profile_template(existing_profiles: list[dict]) -> dict:
    custom = next((item for item in existing_profiles if item.get("relayMode") != "official"), None)
    if custom:
        template = dict(custom)
        for key in ("id", "name", "upstreamBaseUrl", "configContents", "authContents", "modelList"):
            template.pop(key, None)
        return template
    return {
        "protocol": "responses",
        "relayMode": "pureApi",
        "officialMixApiKey": "",
        "hideOfficialUsageAlert": False,
        "testModel": "",
        "useCommonConfig": True,
        "contextWindow": "",
        "autoCompactLimit": "",
        "modelInsertMode": "patch",
        "modelWindows": "{}",
        "modelVlm": "{}",
        "vlmModel": "",
        "vlmBaseUrl": "",
        "sub2apiEnabled": False,
    }


def main() -> None:
    if not CC_DB.is_file():
        raise SystemExit("CC Switch provider database not found")
    if not CODEXPP_SETTINGS.is_file():
        raise SystemExit("Codex++ settings not found")

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    backup_dir = BAR_DIR / "migration-backups" / timestamp
    backup_dir.mkdir(parents=True, exist_ok=True)
    sqlite_backup(CC_DB, backup_dir / "cc-switch.db")
    shutil.copy2(CODEXPP_SETTINGS, backup_dir / "codexpp-settings.json")
    if CC_SETTINGS.is_file():
        shutil.copy2(CC_SETTINGS, backup_dir / "cc-switch-settings.json")

    sqlite_backup(CC_DB, BAR_DB)
    cc_settings = read_json(CC_SETTINGS, {})
    current_provider = str(cc_settings.get("currentProviderCodex") or "")
    write_json_atomic(BAR_SETTINGS, {"currentProviderCodex": current_provider})

    connection = sqlite3.connect(f"file:{CC_DB}?mode=ro", uri=True)
    rows = connection.execute(
        "SELECT id,name,category,is_current,settings_config FROM providers "
        "WHERE app_type='codex' ORDER BY sort_index,created_at"
    ).fetchall()
    connection.close()

    codexpp = read_json(CODEXPP_SETTINGS, {})
    profiles = [item for item in codexpp.get("relayProfiles", []) if isinstance(item, dict)]
    template = profile_template(profiles)
    profile_by_id = {str(item.get("id")): item for item in profiles}
    url_to_id = {
        str(item.get("upstreamBaseUrl") or "").rstrip("/"): str(item.get("id"))
        for item in profiles if item.get("upstreamBaseUrl")
    }
    mapping: dict[str, str] = {}

    for provider_id, name, category, is_current, serialized in rows:
        settings = json.loads(serialized)
        config = settings.get("config") if isinstance(settings.get("config"), str) else ""
        auth = settings.get("auth") if isinstance(settings.get("auth"), dict) else {}
        models = settings.get("modelCatalog", {}).get("models", [])
        model_list = "\n".join(
            item["model"] for item in models
            if isinstance(item, dict) and isinstance(item.get("model"), str) and item["model"]
        )
        upstream = base_url(config)

        if category == "official":
            target = next((item for item in profiles if item.get("relayMode") == "official"), None)
            if target is None:
                target = {**template, "id": "default", "name": "OpenAI Official", "relayMode": "official"}
                profiles.insert(0, target)
            target_id = str(target.get("id") or "default")
        else:
            target_id = url_to_id.get(upstream) or provider_id
            target = profile_by_id.get(target_id)
            if target is None:
                target = {**template, "id": target_id}
                profiles.append(target)
                profile_by_id[target_id] = target
            target["name"] = name
            target["relayMode"] = "pureApi"
            target["protocol"] = "responses"
            target["upstreamBaseUrl"] = upstream
            url_to_id[upstream] = target_id

        target["configContents"] = config
        target["authContents"] = json.dumps(auth, ensure_ascii=False, indent=2)
        target["modelList"] = model_list
        mapping[provider_id] = target_id
        if is_current:
            codexpp["activeRelayId"] = target_id

    codexpp["relayProfiles"] = profiles
    codexpp["relayProfilesEnabled"] = True
    codexpp["providerSyncEnabled"] = True
    write_json_atomic(CODEXPP_SETTINGS, codexpp)
    write_json_atomic(BAR_MAPPING, mapping)

    print(f"Migrated {len(rows)} Codex providers; backup: {backup_dir}")


if __name__ == "__main__":
    main()
