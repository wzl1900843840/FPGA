"""本机偏好：主题等。写在工程根 config/host_console.json，损坏时回退默认值。"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "config" / "host_console.json"

DEFAULTS = {"theme": "graphite"}


def load() -> dict:
    data = dict(DEFAULTS)
    try:
        with PATH.open(encoding="utf-8") as stream:
            stored = json.load(stream)
        if isinstance(stored, dict):
            data.update({k: v for k, v in stored.items() if k in DEFAULTS})
    except (OSError, json.JSONDecodeError):
        pass
    if data["theme"] == "ink":
        data["theme"] = "graphite"
    return data


def save(**changes) -> dict:
    data = load()
    data.update({k: v for k, v in changes.items() if k in DEFAULTS})
    try:
        PATH.parent.mkdir(parents=True, exist_ok=True)
        PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass
    return data
