"""日志：先落盘再允许确认。JSONL 追加写 + CSV 导出 + 回放读取。"""
from __future__ import annotations

import csv
import json
import os
from datetime import datetime
from pathlib import Path

CSV_COLUMNS = ["时间", "会话", "方向", "类型", "原始报文", "说明"]


class Journal:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.path.open("a", encoding="utf-8", buffering=1)
        self.count = 0
        self.failed = False

    def write(self, entry: dict):
        record = {"ts": datetime.now().astimezone().isoformat(timespec="milliseconds"), **entry}
        self.handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.handle.flush()
        os.fsync(self.handle.fileno())
        self.count += 1

    def close(self):
        try:
            self.handle.close()
        except Exception:
            pass


def export_csv(source: Path, destination: Path) -> int:
    rows = 0
    with Path(source).open(encoding="utf-8") as stream, \
            Path(destination).open("w", encoding="utf-8-sig", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(CSV_COLUMNS)
        for line in stream:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            shape = {"rx": "RX", "tx": "TX"}.get(item.get("dir", ""), item.get("dir", ""))
            writer.writerow([
                item.get("ts", ""), item.get("session", ""), shape,
                item.get("kind", ""), item.get("raw", ""), item.get("note", ""),
            ])
            rows += 1
    return rows


def read_entries(path: Path, limit: int = 20000):
    entries = []
    try:
        with Path(path).open(encoding="utf-8") as stream:
            for line in stream:
                if len(entries) >= limit:
                    break
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return entries
