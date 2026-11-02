"""串口协议编解码。只解释字节，不碰界面、不触发控制。

覆盖现有 v1（RESCUE/ELEV/BOOT/OK/ERR/PIC/VOL/PRD/BRT/READY）与
拟定 v1.1 扩展（INFO/STAT/FLOOR/COMM）。未知报文一律保留原文，不猜测字段。
"""
from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field

MAX_LINE = 40          # FPGA 输入行上限（不含 CRLF）
MAX_RX_LINE = 512      # 主机收行上限

FLOOR_PAT = r"(?:--|B[1-9]|[0-9]{2})"

_RESCUE = re.compile(
    rf"RESCUE,ID=([0-9A-Fa-f]{{4}}),A=([01]),F=({FLOOR_PAT}),D=([UDS]),"
    r"DO=([OCM]),S=([ULB]),E=([0-9A-Fa-f]{2})\Z"
)
_STATUS = re.compile(r"RESCUE,ID=([0-9A-Fa-f]{4}),A=([01]),C=(IDLE|WAIT|ACKED|TIMEOUT)\Z")
_COMM = re.compile(r"COMM,ID=([0-9A-Fa-f]{4}),A=([01]),C=(IDLE|WAIT|ACKED|TIMEOUT)\Z")
_BOOT = re.compile(
    r"BOOT,SD=([0-9A-Fa-f]{4}),SC=([0-9A-Fa-f]{4}),P1=([0-9A-Fa-f]{4}),"
    r"TF=([0-9A-Fa-f]{4}),P5=([0-9A-Fa-f]{4}),V=([0-9A-Fa-f]{2})\Z"
)
_ELEV = re.compile(rf"ELEV=F({FLOOR_PAT}),D=([UDS]),DO=([OCM])(?:,A=([01]))?\Z")
_INFO = re.compile(
    r"INFO,P=([0-9A-Fa-f]{2}),FW=([0-9A-Fa-f]{4}),HW=([A-Za-z0-9_-]{1,12}),"
    r"CAP=([0-9A-Fa-f]{4})\Z"
)
_STAT = re.compile(
    rf"STAT,F=({FLOOR_PAT}),D=([UDS]),DO=([OCM]),A=([01]),S=([ULBN]),"
    r"C=(IDLE|WAIT|ACKED|TIMEOUT),I=([0-9A-Fa-f]{4}),E=([0-9A-Fa-f]{2}),"
    r"M=([0-9A-Fa-f]{2})\Z"
)
_ERR_SYS = re.compile(r"ERR ([0-9A-Fa-f]{2})\Z")
_ERR_CMD = re.compile(r"ERR(?: ([A-Z]{3,6}))?\Z")
_PIC = re.compile(r"PIC ([1-5]) ([A-Za-z])\Z")
_VOL = re.compile(r"VOL ([0-9A-Fa-f]{2})\Z")
_PRD = re.compile(r"PRD ([0-9A-Fa-f]{5})ms\Z")
_BRT = re.compile(r"BRT ([0-9A-Fa-f]{2})\Z")

READY = "MEDIA PLAYER READY"

# v1.1 能力位
CAP_FLOOR = 0x0001
CAP_STAT = 0x0002
CAP_INFO = 0x0004
CAP_COMM = 0x0008

COMM_STATES = ("IDLE", "WAIT", "ACKED", "TIMEOUT")


@dataclass
class Message:
    """一条已分类的完整行。raw 永远保留原始文本。"""

    kind: str
    raw: str
    data: dict = field(default_factory=dict)


def _fail(raw: str, reason: str) -> Message:
    return Message("invalid", raw, {"reason": reason})


def parse_line(text: str) -> Message:
    """把一行（不含 CRLF）解析成 Message。绝不抛出异常。"""
    line = text.strip("\r\n")
    if not line:
        return Message("blank", "")
    if line == READY:
        return Message("ready", line)

    if line.startswith("RESCUE,"):
        if not re.fullmatch(r"RESCUE,.*\*[0-9A-Fa-f]{4}", line):
            return _fail(line, "RESCUE 缺少 CRC")
        body, supplied_crc = line.rsplit("*", 1)
        if crc16_ccitt_false(body.encode("ascii")) != int(supplied_crc, 16):
            return _fail(line, "RESCUE CRC 错误")
        line = body
        match = _RESCUE.match(line)
        if match:
            event_id, active, floor, direction, door, source, error = match.groups()
            return Message(
                "rescue",
                line,
                {
                    "id": event_id.upper(),
                    "active": active == "1",
                    "floor": floor.upper(),
                    "direction": direction,
                    "door": door,
                    "source": source,
                    "error": error.upper(),
                },
            )
        match = _STATUS.match(line)
        if match:
            event_id, active, state = match.groups()
            return Message(
                "status",
                line,
                {"id": event_id.upper(), "active": active == "1", "state": state},
            )
        return _fail(line, "RESCUE 字段格式无效")

    if line.startswith("COMM,"):
        match = _COMM.match(line)
        if not match:
            return _fail(line, "COMM 字段格式无效")
        event_id, active, state = match.groups()
        return Message(
            "comm",
            line,
            {"id": event_id.upper(), "active": active == "1", "state": state},
        )

    if line.startswith("STAT,"):
        match = _STAT.match(line)
        if not match:
            return _fail(line, "STAT 字段格式无效")
        floor, direction, door, active, source, state, event_id, error, mask = match.groups()
        return Message(
            "stat",
            line,
            {
                "floor": floor.upper(),
                "direction": direction,
                "door": door,
                "active": active == "1",
                "source": source,
                "state": state,
                "id": event_id.upper(),
                "error": error.upper(),
                "pic_mask": int(mask, 16),
            },
        )

    if line.startswith("ELEV"):
        match = _ELEV.match(line)
        if not match:
            return _fail(line, "ELEV 字段格式无效")
        floor, direction, door, active = match.groups()
        return Message(
            "elev",
            line,
            {
                "floor": floor.upper(),
                "direction": direction,
                "door": door,
                "active": None if active is None else active == "1",
            },
        )

    if line.startswith("BOOT,"):
        match = _BOOT.match(line)
        if not match:
            return _fail(line, "BOOT 字段格式无效")
        numbers = [int(group, 16) for group in match.groups()]
        return Message(
            "boot",
            line,
            {
                "sd_ms": numbers[0],
                "scan_ms": numbers[1],
                "pic1_ms": numbers[2],
                "tf_ms": numbers[3],
                "pic5_ms": numbers[4],
                "valid": numbers[5],
            },
        )

    if line.startswith("INFO,"):
        match = _INFO.match(line)
        if not match:
            return _fail(line, "INFO 字段格式无效")
        version, firmware, hardware, caps = match.groups()
        return Message(
            "info",
            line,
            {
                "proto": int(version, 16),
                "firmware": firmware.upper(),
                "hardware": hardware.upper(),
                "caps": int(caps, 16),
            },
        )

    if line == "OK":
        return Message("ok", line)

    match = _ERR_SYS.match(line)
    if match:
        return Message("err", line, {"scope": "system", "code": match.group(1).upper()})
    match = _ERR_CMD.match(line)
    if match:
        return Message("err", line, {"scope": "command", "code": (match.group(1) or "").upper()})

    match = _PIC.match(line)
    if match:
        return Message("pic", line, {"page": int(match.group(1)), "state": match.group(2).upper()})
    match = _VOL.match(line)
    if match:
        return Message("vol", line, {"value": int(match.group(1), 16)})
    match = _PRD.match(line)
    if match:
        return Message("prd", line, {"ms": int(match.group(1), 16)})
    match = _BRT.match(line)
    if match:
        return Message("brt", line, {"value": int(match.group(1), 16)})

    return Message("unknown", line)


# --------------------------------------------------------------------------
# 发送侧
# --------------------------------------------------------------------------


class ProtocolError(ValueError):
    """命令参数非法，禁止写出。"""


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


class SecureSession:
    """每次连接随机会话号；写入序号只在本会话内递增。"""
    def __init__(self, sid: int | None = None):
        self.sid = secrets.randbits(32) if sid is None else sid
        self.seq = 0

    def frame(self, payload: str, *, hello: bool = False) -> bytes:
        if not payload.isascii() or any(ord(c) < 32 or ord(c) > 126 for c in payload):
            raise ProtocolError("写入仅接受单行可打印 ASCII")
        if 1 + 8 + 1 + 4 + 1 + len(payload) + 5 > MAX_LINE:
            raise ProtocolError("受保护帧超过 FPGA 40 字节上限")
        if hello:
            if payload != "HELLO":
                raise ProtocolError("会话首帧必须为 HELLO")
            seq = 0
        else:
            if self.seq == 0xFFFF:
                raise ProtocolError("序号已用尽，请重新连接建立新会话")
            self.seq += 1
            seq = self.seq
        body = f"@{self.sid:08X}:{seq:04X}:{payload}"
        return f"{body}*{crc16_ccitt_false(body.encode('ascii')):04X}\r\n".encode("ascii")


def _check_floor(floor: str) -> str:
    text = str(floor).strip().upper()
    if text.isdigit():
        value = int(text)
        if 0 <= value <= 99:
            return f"{value:02d}"
    if text.startswith("B") and text[1:].isdigit() and 1 <= int(text[1:]) <= 9:
        return text
    if text == "--":
        return "--"
    raise ProtocolError(f"楼层码无效：{floor}")


def _check_choice(value: str, allowed: str, name: str) -> str:
    text = str(value).strip().upper()
    if text not in allowed:
        raise ProtocolError(f"{name}取值无效：{value}")
    return text


def _frame(body: str) -> bytes:
    if len(body) > MAX_LINE:
        raise ProtocolError(f"命令超过 {MAX_LINE} 字节：{len(body)}")
    if not body.isascii():
        raise ProtocolError("命令只能包含 ASCII")
    return (body + "\r\n").encode("ascii")


def cmd_ack(event_id: str) -> bytes:
    text = str(event_id).strip().upper()
    if not re.fullmatch(r"[0-9A-F]{4}", text):
        raise ProtocolError(f"事件编号无效：{event_id}")
    return _frame(f"ACK={text}")


def cmd_raw(text: str) -> bytes:
    """调试区单行 ASCII 发送；固定追加 CRLF，拒绝多行及控制字符。"""
    if not isinstance(text, str) or not text.strip(" "):
        raise ProtocolError("请输入要发送的命令")
    if any(not 32 <= ord(char) <= 126 for char in text):
        raise ProtocolError("仅支持单行可打印 ASCII，请勿输入中文或换行")
    body = text.strip(" ")
    if body not in ("BOOT?", "RESCUE?", "ELEV?", "SUB?", "INFO?", "STAT?") and not body.startswith(("FLOOR=", "ALERT=", "ACK=", "SUB=")):
        raise ProtocolError("仅允许只读查询及受保护的 FLOOR/ALERT/ACK/SUB 写入")
    return _frame(body)


def cmd_subtitle(text: str) -> bytes:
    """Text supported by the FPGA subtitle renderer; reserved words are commands."""
    if not isinstance(text, str) or not 1 <= len(text) <= 12:
        raise ProtocolError("字幕须为 1～12 个可打印 ASCII 字符")
    if any(not 32 <= ord(c) <= 126 for c in text):
        raise ProtocolError("自定义字幕仅支持可打印 ASCII；中文请使用内置短句")
    normalized = text.upper()
    if any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :.,!?-+_/" for c in normalized):
        raise ProtocolError("设备字库仅支持英文字母、数字、空格及 : . , ! ? - + _ /")
    if text.endswith(" "):
        raise ProtocolError("字幕末尾不能有空格")
    if normalized in ("ON", "OFF", "CN", "SAVE") or not text.strip():
        raise ProtocolError("该文字是设备保留命令，请换一种表达")
    return _frame("SUB=" + normalized)


def cmd_query(name: str) -> bytes:
    table = {"rescue": "RESCUE?", "elev": "ELEV?", "boot": "BOOT?", "info": "INFO?", "stat": "STAT?"}
    if name not in table:
        raise ProtocolError(f"未知查询：{name}")
    return _frame(table[name])


def cmd_floor(floor: str, direction: str, door: str) -> bytes:
    """v1.1 独立楼层更新：不触碰 UART 告警。"""
    checked_floor = _check_floor(floor)
    if checked_floor == "--":
        raise ProtocolError("未知楼层不能作为写入目标")
    return _frame(
        "FLOOR=F{0},D={1},DO={2}".format(
            checked_floor,
            _check_choice(direction, "UDS", "方向"),
            _check_choice(door, "OCM", "门状态"),
        )
    )


def cmd_elev(floor: str, direction: str, door: str, alert: bool = False) -> bytes:
    raise ProtocolError("旧版 ELEV 写入已禁用；请使用 FLOOR 和独立 ALERT")


def cmd_alert(on: bool) -> bytes:
    return _frame("ALERT=ON" if on else "ALERT=OFF")


# --------------------------------------------------------------------------
# 展示辅助
# --------------------------------------------------------------------------

DIRECTION_TEXT = {"U": "上行", "D": "下行", "S": "停止"}
DIRECTION_GLYPH = {"U": "▲", "D": "▼", "S": "■"}
DOOR_TEXT = {"O": "开门", "C": "关门", "M": "未知"}
SOURCE_TEXT = {"U": "串口", "L": "本地", "B": "双来源", "N": "无来源"}
COMM_TEXT = {"IDLE": "空闲", "WAIT": "等待确认", "ACKED": "设备已确认", "TIMEOUT": "确认超时"}


def floor_index(floor: str) -> int | None:
    """把楼层码变成 1..5 的索引，用于演示与井道定位；范围外返回 None。"""
    if not floor or floor == "--":
        return None
    if floor.startswith("B"):
        return None
    try:
        value = int(floor)
    except ValueError:
        return None
    return value if 1 <= value <= 5 else None
