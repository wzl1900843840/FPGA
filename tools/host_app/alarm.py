"""求援告警生命周期。业务有效性与通信确认是两个正交的轴，不合并成单一状态。"""
from __future__ import annotations

from dataclasses import dataclass, field

from .protocol import Message

ACK_TEXT = {
    "none": "等待接收确认",
    "sending": "确认发送中",
    "sent": "确认已发出，待设备回执",
    "acked": "设备已接受接收确认",
    "timeout": "设备确认超时",
    "blocked": "记录失败，禁止确认",
}


@dataclass
class AlarmEvent:
    id: str
    floor: str
    direction: str
    door: str
    source: str
    error: str
    first_ts: float
    last_ts: float
    generation: int = 1
    count: int = 1
    ack: str = "none"
    ack_ts: float = 0.0
    resolved: bool = False
    resolved_ts: float = 0.0
    reason: str = ""
    conflict: bool = False
    journaled: bool = True
    trace: list = field(default_factory=list)

    @property
    def active(self) -> bool:
        return not self.resolved

    def note(self, ts: float, text: str):
        self.trace.append((ts, text))

    def duration(self, now: float) -> float:
        return max(0.0, (self.resolved_ts or now) - self.first_ts)


class AlarmManager:
    def __init__(self):
        self.current: AlarmEvent | None = None
        self.history: list[AlarmEvent] = []
        self.total_events = 0
        self.acked_events = 0
        self._generation = 0

    # ------------------------------------------------------------------
    def on_rescue(self, msg: Message, now: float) -> dict:
        data = msg.data
        events: dict = {}
        if data["active"]:
            fresh = self.current is None or self.current.resolved or self.current.id != data["id"]
            if fresh:
                if self.current and not self.current.resolved:
                    self._close(self.current, now, "被新事件替代")
                    events["superseded"] = self.current.id
                self._generation += 1
                event = AlarmEvent(
                    id=data["id"], floor=data["floor"], direction=data["direction"],
                    door=data["door"], source=data["source"], error=data["error"],
                    first_ts=now, last_ts=now, generation=self._generation,
                )
                event.note(now, "首次到达")
                self.total_events += 1
                self.current = event
                events["new"] = event
            else:
                event = self.current
                same = (event.floor, event.direction, event.door, event.source, event.error) == (
                    data["floor"], data["direction"], data["door"], data["source"], data["error"])
                event.count += 1
                event.last_ts = now
                if same:
                    event.note(now, f"重发第 {event.count} 次")
                    events["repeat"] = event
                else:
                    event.conflict = True
                    event.note(now, "同编号内容冲突")
                    events["conflict"] = event
        else:
            if self.current and not self.current.resolved:
                self._close(self.current, now, "设备恢复报文")
                events["resolved"] = self.current
        return events

    def _close(self, event: AlarmEvent, now: float, reason: str):
        event.resolved = True
        event.resolved_ts = now
        event.reason = reason
        event.note(now, reason)
        self.history.append(event)
        if len(self.history) > 200:
            del self.history[: len(self.history) - 200]

    # ------------------------------------------------------------------
    def on_status(self, msg: Message, now: float) -> dict:
        state = msg.data["state"]
        event = self.current
        if event is None or event.resolved or msg.data["id"] != event.id:
            return {}
        if state == "ACKED" and event.ack != "acked":
            event.ack = "acked"
            event.ack_ts = now
            self.acked_events += 1
            event.note(now, "设备接受确认")
            return {"acked": event}
        if state == "TIMEOUT" and event.ack in ("none", "sent", "sending"):
            event.ack = "timeout"
            event.note(now, "设备报告确认超时")
            return {"timeout": event}
        if state == "IDLE" and not msg.data["active"]:
            self._close(event, now, "查询显示告警已解除")
            return {"resolved": event}
        return {}

    # ------------------------------------------------------------------
    def request_ack(self, now: float, journal_ok: bool) -> tuple[bool, str]:
        event = self.current
        if event is None or event.resolved:
            return False, "没有有效的当前事件"
        if not journal_ok:
            return False, "日志写入失败，禁止发送确认"
        if event.conflict:
            return False, "同一编号内容冲突，请先查询核实"
        if event.ack in ("sending", "acked"):
            return False, ACK_TEXT[event.ack]
        if not event.id.isalnum():
            return False, "事件编号缺失"
        event.ack = "sending"
        event.note(now, "操作者点击收到响应")
        return True, ""

    def mark_sent(self, now: float):
        if self.current and self.current.ack == "sending":
            self.current.ack = "sent"
            self.current.ack_ts = now
            self.current.note(now, "ACK 完整写出")

    def mark_failed(self, now: float, reason: str):
        if self.current and self.current.ack == "sending":
            self.current.ack = "none"
            self.current.note(now, f"发送失败：{reason}")

    def block(self, reason: str):
        if self.current and not self.current.resolved:
            self.current.ack = "blocked"
            self.current.journaled = False
            self.current.note(self.current.first_ts, reason)

    # ------------------------------------------------------------------
    def snapshot(self, now: float) -> dict | None:
        event = self.current
        if event is None:
            return None
        return {
            "id": event.id,
            "floor": event.floor,
            "direction": event.direction,
            "door": event.door,
            "source": event.source,
            "error": event.error,
            "first": event.first_ts,
            "duration": event.duration(now),
            "count": event.count,
            "ack": event.ack,
            "acked": event.ack == "acked",
            "conflict": event.conflict,
            "resolved": event.resolved,
            "resolved_ts": event.resolved_ts,
            "reason": event.reason,
            "journaled": event.journaled,
            "generation": event.generation,
            "trace": list(event.trace),
            "total": self.total_events,
            "acked_total": self.acked_events,
        }
