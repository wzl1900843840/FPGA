"""设备状态仓库。每个字段独立记录来源与时刻，避免把不同刷新频率的数据混成一个真假值。"""
from __future__ import annotations

import secrets
import time
from dataclasses import dataclass
from typing import Any

from .protocol import Message

FRESH_S = 2.4          # 轮询 2s，超过一个周期视为待刷新
STALE_S = 6.0          # 计划规定的失联门限


@dataclass
class Field:
    value: Any = None
    source: str = "none"
    ts: float = 0.0
    valid: bool = False

    def age(self, now: float) -> float:
        return now - self.ts if self.valid else float("inf")

    def fresh(self, now: float, limit: float = FRESH_S) -> bool:
        return self.valid and (now - self.ts) <= limit


class DeviceState:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self.session = ""
        self.session_reason = ""
        self.session_ts = 0.0
        self.floor = Field("--")
        self.direction = Field("S")
        self.door = Field("C")
        self.alert = Field(False)
        self.comm = Field("IDLE")
        self.error = Field("--")
        self.event_id = Field("0000")
        self.pic_mask = Field(0)
        self.info: dict = {}
        self.boot: dict | None = None
        self.rx_lines = 0
        self.tx_lines = 0
        self.invalid_lines = 0
        self.last_valid = 0.0
        self.last_change = 0.0

    # ------------------------------------------------------------------
    def new_session(self, reason: str, now: float | None = None) -> str:
        now = now if now is not None else self._clock()
        tail = f"{int(now * 1000) % 0x100000:05X}"
        self.session = f"{tail}-{secrets.token_hex(1).upper()}"
        self.session_reason = reason
        self.session_ts = now
        self.floor = Field("--")
        self.direction = Field("S")
        self.door = Field("C")
        self.alert = Field(False)
        self.comm = Field("IDLE")
        self.error = Field("--")
        self.event_id = Field("0000")
        self.pic_mask = Field(0)
        self.boot = None
        self.last_valid = 0.0
        return self.session

    # ------------------------------------------------------------------
    def apply(self, msg: Message, now: float) -> dict:
        """吸收一条报文，返回发生变化的字段（供日志与界面提示）。"""
        changes: dict = {}
        kind = msg.kind
        if kind in ("blank",):
            return changes
        if kind == "invalid":
            self.invalid_lines += 1
            self.rx_lines += 1
            return {"invalid": msg.data.get("reason", "")}
        if kind == "unknown":
            self.rx_lines += 1
            return {"unknown": True}

        self.rx_lines += 1
        self.last_valid = now

        def put(name: str, field: Field, value, source: str):
            if field.value != value:
                changes[name] = value
                self.last_change = now
            field.value = value
            field.source = source
            field.ts = now
            field.valid = True

        if kind == "rescue":
            put("alert", self.alert, msg.data["active"], "rescue")
            put("event_id", self.event_id, msg.data["id"], "rescue")
        elif kind == "status":
            put("comm", self.comm, msg.data["state"], "status")
            put("event_id", self.event_id, msg.data["id"], "status")
        elif kind == "comm":
            put("comm", self.comm, msg.data["state"], "comm")
        elif kind == "elev":
            put("floor", self.floor, msg.data["floor"], "elev")
            put("direction", self.direction, msg.data["direction"], "elev")
            put("door", self.door, msg.data["door"], "elev")
            if msg.data["active"] is not None:
                put("alert", self.alert, msg.data["active"], "elev")
        elif kind == "stat":
            put("floor", self.floor, msg.data["floor"], "stat")
            put("direction", self.direction, msg.data["direction"], "stat")
            put("door", self.door, msg.data["door"], "stat")
            put("alert", self.alert, msg.data["active"], "stat")
            put("comm", self.comm, msg.data["state"], "stat")
            put("event_id", self.event_id, msg.data["id"], "stat")
            put("error", self.error, msg.data["error"], "stat")
            put("pic_mask", self.pic_mask, msg.data["pic_mask"], "stat")
        elif kind == "info":
            self.info = dict(msg.data)
        elif kind == "boot":
            self.boot = dict(msg.data)
        elif kind == "err":
            if msg.data.get("scope") == "system":
                put("error", self.error, msg.data["code"], "err")
            else:
                changes["command_error"] = msg.data.get("code") or "命令被拒绝"
        elif kind == "pic":
            changes["pic"] = msg.data
        return changes

    # ------------------------------------------------------------------
    def known_floor(self) -> int | None:
        text = self.floor.value
        if not self.floor.valid or not text or text == "--":
            return None
        if text.startswith("B"):
            return None
        try:
            value = int(text)
        except (TypeError, ValueError):
            return None
        return value if 1 <= value <= 5 else None

    def control_ready(self, now: float) -> bool:
        """Fresh state permits explicit initialization even at the boot F00 value."""
        return bool(self.floor.valid and self.direction.valid and self.door.valid
                    and self.floor.age(now) <= STALE_S and self.alert.valid
                    and self.alert.age(now) <= STALE_S and not self.alert.value)

    def snapshot(self, now: float) -> dict:
        return {
            "session": self.session,
            "session_reason": self.session_reason,
            "session_age": now - self.session_ts if self.session_ts else 0.0,
            "floor": self.floor.value if self.floor.valid else "--",
            "floor_src": self.floor.source if self.floor.valid else "none",
            "floor_age": self.floor.age(now),
            "status_received": self.floor.valid and self.direction.valid and self.door.valid,
            "direction_valid": self.direction.valid,
            "door_valid": self.door.valid,
            "comm_valid": self.comm.valid,
            "error_valid": self.error.valid,
            "direction": self.direction.value if self.direction.valid else "S",
            "door": self.door.value if self.door.valid else "C",
            "alert": bool(self.alert.value) if self.alert.valid else False,
            "alert_src": self.alert.source if self.alert.valid else "none",
            "alert_age": self.alert.age(now),
            "comm": self.comm.value if self.comm.valid else "IDLE",
            "error": self.error.value if self.error.valid else "--",
            "event_id": self.event_id.value if self.event_id.valid else "0000",
            "pic_mask": int(self.pic_mask.value or 0),
            "info": dict(self.info),
            "boot": dict(self.boot) if self.boot else None,
            "rx_lines": self.rx_lines,
            "tx_lines": self.tx_lines,
            "invalid_lines": self.invalid_lines,
            "link_age": (now - self.last_valid) if self.last_valid else float("inf"),
            # Legacy ELEV? has no validity bit: boot F00 is not an established floor.
            "known": self.floor.valid and self.floor.value not in ("--", "00"),
            "demo_floor": self.known_floor(),
        }
