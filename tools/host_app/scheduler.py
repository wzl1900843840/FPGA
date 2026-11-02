"""发送调度：一条普通事务在途，ACK 可插队，轮询同类合并。"""
from __future__ import annotations

import heapq
import time
from dataclasses import dataclass, field

PRIO_ACK = 0
PRIO_CONTROL = 1
PRIO_POLL = 2
PRIO_DEBUG = 3

REPLY_KINDS = {"ok", "err", "elev", "stat", "info", "boot", "status",
               "pic", "vol", "prd", "brt"}
QUERY_REPLIES = {"elev": "elev", "stat": "stat", "info": "info",
                 "boot": "boot", "rescue": "status"}


@dataclass(order=True)
class Command:
    priority: int
    seq: int
    label: str = field(compare=False)
    payload: bytes = field(compare=False)
    expects: bool = field(default=True, compare=False)
    coalesce: str = field(default="", compare=False)
    replies: tuple[str, ...] = field(default=(), compare=False)


class Scheduler:
    def __init__(self, write, clock=time.monotonic, timeout: float = 0.5):
        self._write = write
        self._clock = clock
        self.timeout = timeout
        self._queue: list[Command] = []
        self._seq = 0
        self._polls: set[str] = set()
        self.active: Command | None = None
        self.active_ts = 0.0
        self.timeouts = 0

    # ------------------------------------------------------------------
    def enqueue(self, label: str, payload: bytes, priority: int = PRIO_CONTROL,
                expects: bool = True, coalesce: str = "",
                replies: tuple[str, ...] = ()) -> bool:
        if coalesce:
            if coalesce in self._polls:
                return False
            self._polls.add(coalesce)
        self._seq += 1
        heapq.heappush(self._queue, Command(priority, self._seq, label, payload, expects, coalesce, replies))
        return True

    def has_control(self) -> bool:
        return self.active is not None or any(
            c.priority <= PRIO_CONTROL for c in self._queue)

    def discard_prefix(self, prefix: str):
        """取消尚未写出的指定命令，不影响在途事务或 ACK。"""
        discarded = [c for c in self._queue if c.label.startswith(prefix)]
        self._queue = [c for c in self._queue if not c.label.startswith(prefix)]
        for command in discarded:
            if command.coalesce:
                self._polls.discard(command.coalesce)
        heapq.heapify(self._queue)

    def clear(self, priority_max: int = PRIO_CONTROL) -> list[str]:
        """丢弃未写出的低优先级命令，返回被丢弃的标签。"""
        dropped, keep = [], []
        for command in self._queue:
            if command.priority <= priority_max:
                dropped.append(command.label)
                if command.coalesce:
                    self._polls.discard(command.coalesce)
            else:
                keep.append(command)
        self._queue = keep
        heapq.heapify(self._queue)
        return dropped

    # ------------------------------------------------------------------
    def poll(self, now: float) -> list[tuple[str, str]]:
        """执行可发送的命令，返回 [(结果, 标签)]，结果为 tx-ok/tx-fail/timeout。"""
        sent: list[tuple[str, str]] = []
        # ACK 允许在普通事务在途时插入
        while self._queue and self._queue[0].priority == PRIO_ACK:
            command = heapq.heappop(self._queue)
            try:
                self._write(command.payload)
                sent.append(("tx-ok", command.label))
            except Exception:
                sent.append(("tx-fail", command.label))
        if self.active is not None:
            if now - self.active_ts > self.timeout:
                self.timeouts += 1
                sent.append(("timeout", self.active.label))
                self.active = None
                return sent  # 超时后先停下，由上层改用状态查询重新同步
            return sent
        while self._queue:
            command = heapq.heappop(self._queue)
            if command.coalesce:
                self._polls.discard(command.coalesce)
            try:
                self._write(command.payload)
            except Exception:
                sent.append(("tx-fail", command.label))
                continue
            sent.append(("tx-ok", command.label))
            if command.expects:
                self.active = command
                self.active_ts = now
                break
        return sent

    def on_line(self, kind: str) -> str | None:
        """普通回包匹配在途事务；异步事件不占用事务槽。"""
        if self.active is None or kind not in REPLY_KINDS:
            return None
        label = self.active.label
        expected = self.active.replies or (QUERY_REPLIES.get(label, "ok"),)
        if kind not in (*expected, "err"):
            return None
        self.active = None
        return label

    def busy(self) -> bool:
        return self.active is not None

    def size(self) -> int:
        return len(self._queue)
