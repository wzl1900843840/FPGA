"""楼层演示状态机。只产生楼层意图，不直接写串口，也不假设真实轿厢速度。"""
from __future__ import annotations

from .protocol import floor_index

PERIOD = 2.0

# 端点先显示运行方向，再同层停靠；相邻楼层也能看到上行/下行。
SEQUENCE = (
    (1, "S"), (2, "U"), (3, "U"), (4, "U"), (5, "U"), (5, "S"),
    (4, "D"), (3, "D"), (2, "D"), (1, "D"), (1, "S"),
)

STOPPED = "STOPPED"
COMPLETED = "COMPLETED"
RUNNING = "RUNNING"
PAUSED_USER = "PAUSED_USER"
PAUSED_ALARM = "PAUSED_ALARM"
PAUSED_LINK = "PAUSED_LINK"

STATE_TEXT = {
    STOPPED: "未运行",
    COMPLETED: "已到达",
    RUNNING: "运行中",
    PAUSED_USER: "已暂停",
    PAUSED_ALARM: "告警暂停",
    PAUSED_LINK: "链路暂停",
}


class DemoController:
    def __init__(self, clock=None, period: float = PERIOD):
        self.period = period
        self.state = STOPPED
        self.index = 0
        self.deadline = 0.0
        self.step = 0
        self.last_target: tuple[int, str] | None = None
        self.pending_target: tuple[int, str] | None = None
        self.paused_reason = ""
        self.start_floor = 1
        self.end_floor = 5
        self.mode = "roundtrip"
        self.sequence = SEQUENCE

    # ------------------------------------------------------------------
    def start(self, now: float, start_floor: int = 1, end_floor: int = 5,
              mode: str = "roundtrip") -> tuple[int, str]:
        if (type(start_floor) is not int or type(end_floor) is not int or
                not 1 <= start_floor <= 5 or not 1 <= end_floor <= 5):
            raise ValueError("起止楼层必须为 1～5 层的整数")
        if start_floor == end_floor:
            raise ValueError("起点与终点不能相同")
        if mode not in ("single", "roundtrip"):
            raise ValueError("演示模式必须为单程或往返")
        delta = 1 if end_floor > start_floor else -1
        direction = "U" if delta > 0 else "D"
        floors = list(range(start_floor, end_floor + delta, delta))
        sequence = [(start_floor, "S")]
        sequence.extend((f, direction) for f in floors[1:])
        sequence.append((end_floor, "S"))
        if mode == "roundtrip":
            reverse = "D" if delta > 0 else "U"
            sequence.extend((f, reverse) for f in floors[-2::-1])
            sequence.append((start_floor, "S"))
        self.start_floor, self.end_floor, self.mode = start_floor, end_floor, mode
        self.sequence = tuple(sequence)
        self.state = RUNNING
        self.index = 0
        self.step = 1
        self.deadline = now + self.period
        self.last_target = self.sequence[0]
        self.pending_target = self.sequence[0]
        self.paused_reason = ""
        return self.last_target

    def tick(self, now: float) -> tuple[int, str] | None:
        """到点则给出下一个目标；忙时整周期顺延，不补发追赶。"""
        if self.state != RUNNING:
            return None
        if self.pending_target is not None:
            return None  # 等待真实回读，忙时不能越过尚未落实的楼层
        if now < self.deadline:
            return None
        self.deadline = now + self.period
        self.index += 1
        if self.index >= len(self.sequence):
            self.index = 1  # 返回起点后已停靠，不再重复发送同层停止
        self.step += 1
        self.last_target = self.sequence[self.index]
        self.pending_target = self.last_target
        return self.last_target

    def pause(self, reason: str):
        if self.state == RUNNING:
            self.state = PAUSED_ALARM if reason == "alarm" else (
                PAUSED_LINK if reason == "link" else PAUSED_USER)
            self.paused_reason = reason

    def resume(self, now: float, current_floor: str, direction: str = "S") -> bool:
        """只从已回读楼层继续；楼层未知或不在 1～5 时要求重新开始。"""
        if self.state not in (PAUSED_USER, PAUSED_ALARM, PAUSED_LINK):
            return False
        room = floor_index(current_floor or "")
        if room is None:
            return False
        # 选一个"下一步会离开当前层"的位置，避免恢复后原地停一拍
        candidates = [i for i, (floor, _d) in enumerate(self.sequence) if floor == room]
        if not candidates:
            return False
        if direction in ("U", "D"):
            aligned = [i for i in candidates if self.sequence[i][1] == direction]
            candidates = aligned or candidates
        elif direction == "S":
            # 停靠点恢复从同层停止项继续，避免往返端点倒退或重复停靠。
            stopped = [i for i in candidates if self.sequence[i][1] == "S"]
            candidates = stopped or candidates
        self.index = min(candidates, key=lambda i: abs(i - self.index))
        self.state = RUNNING
        self.deadline = now + self.period
        self.pending_target = None
        self.last_target = self.sequence[self.index]
        self.paused_reason = ""
        if self.mode == "single" and self.index == len(self.sequence) - 1:
            self.state = COMPLETED
        return True

    def stop(self):
        self.state = STOPPED
        self.index = 0
        self.step = 0
        self.pending_target = None
        self.deadline = 0.0

    def target_floor(self) -> str:
        if self.pending_target:
            return f"{self.pending_target[0]:02d}"
        return ""

    def applied(self, floor: str, direction: str):
        """设备回读到目标后清除待回读标记。"""
        if not self.pending_target:
            return
        room, want = self.pending_target
        if floor_index(floor) == room and direction == want:
            self.pending_target = None
            if (self.state == RUNNING and self.mode == "single" and
                    self.index == len(self.sequence) - 1):
                self.state = COMPLETED

    # ------------------------------------------------------------------
    def snapshot(self, now: float) -> dict:
        return {
            "state": self.state,
            "text": STATE_TEXT.get(self.state, self.state),
            "step": self.step,
            "period": self.period,
            "next_in": max(0.0, self.deadline - now) if self.state == RUNNING else 0.0,
            "target": self.pending_target,
            "target_floor": f"{self.pending_target[0]:02d}" if self.pending_target else "",
            "running": self.state == RUNNING,
            "paused": self.state.startswith("PAUSED"),
            "start_floor": self.start_floor,
            "end_floor": self.end_floor,
            "mode": self.mode,
            "completed": self.state == COMPLETED,
            "route": f"{self.start_floor}{'↔' if self.mode == 'roundtrip' else '→'}{self.end_floor}",
        }
