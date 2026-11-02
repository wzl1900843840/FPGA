"""串口传输层。工作线程独占端口；模拟设备实现同一接口，便于无硬件演示与自测。"""
from __future__ import annotations

import random
import re
import time

from . import protocol as P


class TransportError(OSError):
    pass


class SerialTransport:
    sim = False

    def __init__(self, port: str):
        self.port = port
        self.name = port
        self._serial = None

    def open(self):
        import serial
        self._serial = serial.Serial(self.port, 115200, timeout=0.02, write_timeout=1)

    def read(self, size: int = 256) -> bytes:
        data = self._serial.read(size)
        return data or b""

    def write(self, data: bytes):
        written = self._serial.write(data)
        if written != len(data):
            raise TransportError("串口写入不完整")
        self._serial.flush()

    def close(self):
        if self._serial is not None:
            try:
                self._serial.close()
            finally:
                self._serial = None


class SimulatedTransport:
    """按现有固件语义回包的最小模拟器，仅用于界面演练，不能替代实板验收。"""

    sim = True
    LATENCY = 0.035
    TIMEOUT_S = 3.0

    def __init__(self, name: str = "SIM-01", alarm_after: float = 0.0):
        self.name = name
        self.port = name
        self._out: list[tuple[float, bytes]] = []
        self._floor = 1
        self._direction = "S"
        self._door = "C"
        self._alert = False
        self._alert_seen = 0.0
        self._event_id = 0
        self._comm = "IDLE"
        self._boot = (101, 220, 830, 850, 1500, 0x1F)
        self._opened = 0.0
        self._alarm_after = alarm_after
        self._alarm_sent = False
        self._next_pic = 9.0
        self._last_ack = None
        self._rng = random.Random(7)
        self._sid = None
        self._seq = 0
        self._previous = ""
        self._subtitle = ""
        self._subtitle_on = False

    # ------------------------------------------------------------------
    def open(self):
        self._opened = time.monotonic()
        self._emit(P.READY, delay=0.35)

    def close(self):
        self._out.clear()

    def read(self, size: int = 256) -> bytes:
        now = time.monotonic()
        ready = []
        while self._out and self._out[0][0] <= now:
            ready.append(self._out.pop(0)[1])
        return b"".join(ready)[:size]

    def write(self, data: bytes):
        text = data.decode("ascii", "replace").strip("\r\n")
        if text.startswith("@"):
            match = re.fullmatch(r"@([0-9A-F]{8}):([0-9A-F]{4}):(.+)\*([0-9A-F]{4})", text)
            if not match or len(text) > 40 or P.crc16_ccitt_false(text.rsplit("*",1)[0].encode("ascii")) != int(match.group(4),16):
                self._emit("ERR")
                return
            sid, seq, payload, _ = match.groups()
            number = int(seq, 16)
            if number == 0 and payload == "HELLO":
                self._sid=sid;self._seq=0;self._previous="";self._emit("OK");return
            if sid != self._sid or number == 0:
                self._emit("ERR");return
            if number == self._seq and text == self._previous:
                self._emit("OK");return
            if number != self._seq+1 or self._seq == 0xFFFF:
                self._emit("ERR");return
            self._seq=number;self._previous=text
            self._handle(payload)
        elif text in ("BOOT?", "RESCUE?", "ELEV?", "SUB?", "INFO?", "STAT?"):
            self._handle(text)
        else:
            self._emit("ERR")

    # ------------------------------------------------------------------
    def _emit(self, text: str, delay: float | None = None):
        if text.startswith("RESCUE,"):
            text += f"*{P.crc16_ccitt_false(text.encode('ascii')):04X}"
        self._out.append((time.monotonic() + (self.LATENCY if delay is None else delay),
                          (text + "\r\n").encode("ascii")))

    def _frame(self, active: bool, state: str) -> str:
        return f"RESCUE,ID={self._event_id:04X},A={1 if active else 0},C={state}"

    def _handle(self, text: str):
        upper = text.upper()
        if upper == "RESCUE?":
            if self._alert:
                self._refresh_comm()
                self._emit(self._frame(True, self._comm))
            else:
                self._emit(self._frame(False, "IDLE"))
        elif upper == "ELEV?":
            self._emit(f"ELEV=F{self._floor:02d},D={self._direction},DO={self._door},"
                       f"A={1 if self._alert else 0}")
        elif upper == "STAT?":
            self._refresh_comm()
            source = "U" if self._alert else "N"
            self._emit(f"STAT,F={self._floor:02d},D={self._direction},DO={self._door},"
                       f"A={1 if self._alert else 0},S={source},C={self._comm},"
                       f"I={self._event_id:04X},E=00,M=1F")
        elif upper == "INFO?":
            self._emit("INFO,P=11,FW=0001,HW=EG4S20,CAP=0007")
        elif upper == "BOOT?":
            sd, scan, p1, tf, p5, valid = self._boot
            self._emit(f"BOOT,SD={sd:04X},SC={scan:04X},P1={p1:04X},TF={tf:04X},"
                       f"P5={p5:04X},V={valid:02X}")
        elif upper.startswith("SUB="):
            value = text[4:]
            if upper == "SUB=ON":
                self._subtitle_on = True
            elif upper == "SUB=OFF":
                self._subtitle_on = False
            elif upper == "SUB=SAVE":
                self._emit("ERR"); return
            elif upper == "SUB=CN":
                self._subtitle = "CN"
            elif len(value) <= 12 and all(32 <= ord(c) <= 126 for c in value):
                self._subtitle = value.upper()
            else:
                self._emit("ERR"); return
            self._emit("OK")
        elif upper.startswith("ACK="):
            target = upper.split("=", 1)[1]
            if self._alert and target == f"{self._event_id:04X}":
                self._comm = "ACKED"
                self._last_ack = target
        elif upper.startswith("FLOOR="):
            if self._parse_floor(text[6:]):
                self._emit("OK")
            else:
                self._emit("ERR FLOOR")
        elif upper.startswith("ELEV="):
            parts = text[5:].split(",")
            if self._parse_floor(",".join(parts)) and len(parts) >= 4 and parts[3].startswith("A="):
                self._alert = parts[3][2:] == "1"
                self._comm = "WAIT" if self._alert else "IDLE"
                if self._alert:
                    self._event_id = (self._event_id + 1) % 0x10000
                    self._alert_seen = time.monotonic()
                self._emit("OK")
            else:
                self._emit("ERR ELEV")
        elif upper == "ALERT=ON":
            self._raise_alarm()
            self._emit("OK")
        elif upper == "ALERT=OFF":
            if self._alert:
                self._event_id = (self._event_id + 1) % 0x10000
            self._alert = False
            self._comm = "IDLE"
            self._emit("OK")
        else:
            self._emit("ERR")

    def _parse_floor(self, body: str) -> bool:
        parts = body.split(",")
        head = parts[0].strip()
        if not head.startswith("F") or not head[1:].isdigit():
            return False
        value = int(head[1:])
        if not 1 <= value <= 5:
            return False
        self._floor = value
        fields = {}
        for part in parts[1:]:
            if "=" in part:
                key, val = part.split("=", 1)
                fields[key.strip().upper()] = val.strip().upper()
        direction = fields.get("D", "")[:1]
        if direction in ("U", "D", "S"):
            self._direction = direction
        door = fields.get("DO", "")[:1]
        if door in ("O", "C", "M"):
            self._door = door
        return True

    def _raise_alarm(self):
        self._event_id = (self._event_id + 1) % 0x10000
        self._alert = True
        self._comm = "WAIT"
        self._alert_seen = time.monotonic()
        self._emit(f"RESCUE,ID={self._event_id:04X},A=1,F={self._floor:02d},"
                   f"D={self._direction},DO={self._door},S=U,E=00")

    def _refresh_comm(self):
        if self._alert and self._comm == "WAIT" and \
                time.monotonic() - self._alert_seen > self.TIMEOUT_S:
            self._comm = "TIMEOUT"

    # -- 供界面按钮调用的模拟动作 ---------------------------------------
    def inject_alarm(self):
        self._raise_alarm()

    def inject_recover(self):
        if self._alert:
            self._event_id = (self._event_id + 1) % 0x10000
        self._alert = False
        self._comm = "IDLE"
        self._emit(f"RESCUE,ID={self._event_id:04X},A=0,F={self._floor:02d},"
                   f"D={self._direction},DO={self._door},S=U,E=00")

    def tick(self):
        """自发事件：启动标志后偶发图片与音量上报，让原始页有真实流量。"""
        if not self._opened:
            return
        now = time.monotonic()
        if self._alarm_after and not self._alarm_sent and now - self._opened > self._alarm_after:
            self._alarm_sent = True
            self._raise_alarm()
        if now - self._opened > self._next_pic:
            self._next_pic = now - self._opened + 11.0
            self._emit(f"PIC {self._rng.randint(1, 5)} {self._rng.choice('AC')}")
            self._emit(f"VOL {self._rng.randint(0x30, 0xFF):02X}")
