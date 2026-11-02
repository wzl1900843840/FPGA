"""核心工作线程：唯一串口拥有者，负责解析、状态、告警、日志、调度与演示推进。"""
from __future__ import annotations

import queue
import threading
import time
import traceback
from collections import deque
from pathlib import Path

from . import protocol as P
from .alarm import AlarmManager
from .demo import COMPLETED, DemoController, RUNNING, STOPPED
from .journal import Journal
from .scheduler import PRIO_ACK, PRIO_CONTROL, PRIO_DEBUG, PRIO_POLL, Scheduler
from .state import FRESH_S, STALE_S, DeviceState
from .transport import SerialTransport, SimulatedTransport

TICK = 0.02
PUBLISH = 0.15
POLL_NORMAL = 2.0
POLL_ALARM = 1.0


class HostCore(threading.Thread):
    def __init__(self, events: queue.Queue, commands: queue.Queue,
                 log_path: Path, clock=time.monotonic):
        super().__init__(daemon=True, name="host-core")
        self.events = events
        self.commands = commands
        self.log_path = Path(log_path)
        self.clock = clock
        self.stop_event = threading.Event()

        self.state = DeviceState(clock)
        self.alarm = AlarmManager()
        self.demo = DemoController()
        self.scheduler: Scheduler | None = None
        self.journal: Journal | None = None
        self.transport = None
        self.caps = 0
        self.secure = P.SecureSession()
        self.secure_ready = False
        self.auto_ack = False
        self.ack_delay = 0.0
        self.link = "offline"
        self.port = ""
        self.connect_ts = 0.0
        self.last_publish = 0.0
        self.last_poll = 0.0
        self.next_ack_at: float | None = None
        self.notice_seq = 0
        self.buffer = bytearray()
        self.overflow = False
        self._pending_writes: deque = deque()
        self.sim_alarm_after = 0.0
        self.replaying = False
        self.errors = 0
        self._sent_step: int | None = None

    # ------------------------------------------------------------------
    def emit(self, payload: dict):
        try:
            self.events.put_nowait(payload)
        except queue.Full:
            pass

    def notice(self, text: str, tone: str = "info"):
        self.notice_seq += 1
        self.emit({"kind": "notice", "text": text, "tone": tone, "seq": self.notice_seq})

    def entry(self, tag: str, text: str, event_id: str = "", floor: str = "",
              status: str = "", tone: str = "mute"):
        self.emit({
            "kind": "entry", "tag": tag, "text": text, "id": event_id,
            "floor": floor, "status": status, "tone": tone, "ts": self.clock(),
            "clock": time.strftime("%H:%M:%S"),
        })

    # ------------------------------------------------------------------
    def run(self):
        while not self.stop_event.is_set():
            try:
                now = self.clock()
                self._drain_commands(now)
                if self.transport is not None:
                    self._pump(now)
                    self._schedule(now)
                self._publish(now)
            except Exception:
                self.errors += 1
                self.notice("内部异常：" + traceback.format_exc(limit=1).strip().splitlines()[-1], "error")
            self.stop_event.wait(TICK)
        self._shutdown()

    # ------------------------------------------------------------------
    def _drain_commands(self, now: float):
        while True:
            try:
                command = self.commands.get_nowait()
            except queue.Empty:
                return
            op = command.get("op")
            try:
                if op == "connect":
                    self._connect(command.get("port", ""), now)
                elif op == "disconnect":
                    self._disconnect("操作者断开")
                elif op == "start":
                    self._start_demo(now, command.get("start_floor", 1),
                                     command.get("end_floor", 5),
                                     command.get("mode", "roundtrip"))
                elif op == "raw_send":
                    self._raw_send(command.get("text", ""), now)
                elif op == "pause":
                    self._pause_demo(now)
                elif op == "resume":
                    self._resume_demo(now)
                elif op == "stop":
                    self._stop_demo(now)
                elif op == "manual":
                    self._manual(command, now)
                elif op == "alert":
                    self._demo_alert(bool(command.get("on")), now)
                elif op == "ack":
                    self._ack(now)
                elif op == "query":
                    self._query(command.get("name", "elev"))
                elif op == "settings":
                    self.auto_ack = bool(command.get("auto_ack", self.auto_ack))
                    self.ack_delay = float(command.get("ack_delay", self.ack_delay))
                elif op == "sim_alarm":
                    self._sim("inject_alarm")
                elif op == "sim_recover":
                    self._sim("inject_recover")
                elif op == "clearlog":
                    self.emit({"kind": "clearlog"})
            except Exception as error:
                self.notice(f"命令失败：{error}", "error")

    # ------------------------------------------------------------------
    def _connect(self, port: str, now: float):
        if self.transport is not None:
            return
        self.emit({"kind": "link", "state": "connecting", "port": port})
        transport = (SimulatedTransport(port, self.sim_alarm_after)
                     if port.upper().startswith("SIM") else SerialTransport(port))
        try:
            transport.open()
            journal = Journal(self.log_path)
        except Exception as error:
            try:
                transport.close()
            except Exception:
                pass
            self.link = "offline"
            self.emit({"kind": "link", "state": "offline", "port": port, "error": str(error)})
            self.notice(f"连接失败：{error}", "error")
            return

        self.transport = transport
        self.journal = journal
        self.port = port
        self.link = "online"
        self.connect_ts = now
        self.caps = 0
        self.state = DeviceState(self.clock)
        self.alarm = AlarmManager()
        self.demo = DemoController(period=2.0)
        self._sent_step = None
        self.buffer.clear()
        self.overflow = False
        self.last_poll = now
        self.next_ack_at = None
        self.secure = P.SecureSession()
        self.secure_ready = False
        session = self.state.new_session("串口连接", now)
        self.scheduler = Scheduler(self._write, self.clock, timeout=0.5)
        self.scheduler.enqueue("hello", self.secure.frame("HELLO", hello=True), PRIO_CONTROL)
        self._log({"dir": "sys", "kind": "session", "raw": "", "session": session,
                   "note": f"新会话 {port}"})
        self.emit({"kind": "link", "state": "online", "port": port,
                   "sim": transport.sim, "session": session})
        self.notice(f"已连接 {port} · 115200 8N1 · 人工确认", "ok")
        self.entry("会话", f"建立会话 {session}（{port}）", status="连接", tone="ok")
        # 能力探测 → 求援状态 → 楼层状态
        if transport.sim:
            self.scheduler.enqueue("info", P.cmd_query("info"), PRIO_DEBUG, coalesce="info")
        self.scheduler.enqueue("rescue", P.cmd_query("rescue"), PRIO_POLL, coalesce="rescue")
        self.scheduler.enqueue("elev", P.cmd_query("elev"), PRIO_POLL, coalesce="elev")

    def _disconnect(self, reason: str):
        if self.transport is None:
            return
        if self.scheduler:
            self.scheduler.clear(PRIO_DEBUG)
        self.demo.stop()
        try:
            self.transport.close()
        except Exception:
            pass
        if self.journal:
            self._log({"dir": "sys", "kind": "session", "raw": "",
                       "session": self.state.session, "note": reason})
            self.journal.close()
        self.transport = None
        self.journal = None
        self.scheduler = None
        self.link = "offline"
        self.entry("链路", reason, status="断开", tone="warn")
        self.emit({"kind": "link", "state": "offline", "port": self.port})

    # ------------------------------------------------------------------
    def _pump(self, now: float):
        try:
            data = self.transport.read(256)
        except Exception as error:
            self._link_lost(f"读取失败：{error}")
            return
        if getattr(self.transport, "sim", False):
            self.transport.tick()
        if not data:
            return
        for byte in data:
            if byte == 10:
                line = bytes(self.buffer)
                self.buffer.clear()
                if self.overflow:
                    self.overflow = False
                    self._invalid("报文超过 512 字节，已丢弃整行")
                else:
                    self._on_line(line, now)
            elif len(self.buffer) < P.MAX_RX_LINE:
                self.buffer.append(byte)
            else:
                self.overflow = True

    def _invalid(self, reason: str):
        self.state.invalid_lines += 1
        self._log({"dir": "rx", "kind": "invalid", "raw": "", "note": reason,
                   "session": self.state.session})
        self.entry("异常", reason, status="丢弃", tone="warn")

    def _on_line(self, raw: bytes, now: float):
        text = raw.decode("ascii", "replace").replace("\r", "")
        message = P.parse_line(text)
        if message.kind == "blank":
            return
        self._log({"dir": "rx", "kind": message.kind, "raw": text,
                   "session": self.state.session, "note": ""})
        self.emit({"kind": "raw", "dir": "rx", "text": text, "tag": message.kind,
                   "clock": time.strftime("%H:%M:%S")})

        if message.kind == "ready":
            self.state.new_session("FPGA 启动标志", now)
            self.secure = P.SecureSession()
            self.secure_ready = False
            self.scheduler.clear(PRIO_DEBUG)
            self.scheduler.active = None
            self.scheduler.enqueue("hello", self.secure.frame("HELLO", hello=True), PRIO_CONTROL)
            if self.transport.sim:
                self.scheduler.enqueue("info", P.cmd_query("info"), PRIO_DEBUG, coalesce="info")
            self.scheduler.enqueue("rescue", P.cmd_query("rescue"), PRIO_POLL, coalesce="rescue")
            self.scheduler.enqueue("elev", P.cmd_query("elev"), PRIO_POLL, coalesce="elev")
            self.demo.pause("link")
            self.next_ack_at = None
            self.entry("启动", "收到 MEDIA PLAYER READY · 新会话", status="重启", tone="warn")
            return
        if message.kind == "invalid":
            self._invalid(message.data.get("reason", "格式无效"))
            return

        self.state.apply(message, now)
        if self.state.alert.valid and self.state.alert.value:
            self.demo.pause("alarm")
            if self.scheduler:
                self.scheduler.discard_prefix("floor:")
                self.scheduler.discard_prefix("raw:")
        if self.link != "online":
            self.link = "online"

        if message.kind == "info":
            self.caps = message.data["caps"]
            self.entry("能力", f"协议 v1.{message.data['proto'] & 0x0F} · "
                               f"CAP={message.data['caps']:04X} · "
                               f"FW={message.data['firmware']}",
                       status="握手", tone="ok")

        if message.kind in ("rescue", "status", "comm"):
            self._on_alarm_message(message, now)

        label = self.scheduler.on_line(message.kind) if self.scheduler else None
        if label and label.startswith("raw:SUB="):
            self.emit({"kind": "subtitle_feedback", "note":
                       "设备回复 OK；画面显示仍取决于字幕开关和当前页面。" if message.kind == "ok"
                       else "设备拒绝字幕命令，请检查设备状态。"})
        if label == "hello":
            self.secure_ready = message.kind == "ok"
        if label and message.kind == "ok" and not label.startswith("floor:"):
            self.entry("命令", f"{label} 已接受", status="OK", tone="mute")
        if message.kind == "err":
            scope = "系统故障" if message.data.get("scope") == "system" else "命令被拒绝"
            self.entry("错误", f"{scope} {message.data.get('code','')}".strip(),
                       status="ERR", tone="warn")
            if message.data.get("scope") == "command" and label in ("info", "stat"):
                self.caps = 0
                self.entry("查询", "设备未实现 INFO/STAT，继续 ELEV? 查询", status="只读", tone="warn")

        self.emit({"kind": "line", "message": message})

    def _on_alarm_message(self, message: P.Message, now: float):
        if message.kind == "rescue":
            if message.data["active"]:
                events = self.alarm.on_rescue(message, now)
                if "new" in events:
                    event = events["new"]
                    self.demo.pause("alarm")
                    if self.scheduler:
                        self.scheduler.discard_prefix("floor:")
                        self.scheduler.discard_prefix("raw:")
                    self.next_ack_at = (now + self.ack_delay) if self.auto_ack else None
                    self.entry("求援", f"楼层 {event.floor} · 来源 "
                                       f"{P.SOURCE_TEXT.get(event.source, event.source)} · "
                                       f"故障 {event.error}",
                               event_id=event.id, floor=event.floor,
                               status="未确认", tone="alarm")
                    self.notice(f"求援事件 {event.id} 置顶", "alarm")
                elif "repeat" in events:
                    event = events["repeat"]
                    self.entry("重发", f"第 {event.count} 次接收，内容一致", event_id=event.id,
                               floor=event.floor, status="未确认", tone="warn")
                elif "conflict" in events:
                    self.entry("冲突", "同编号内容不一致，禁止自动确认", event_id=message.data["id"],
                               status="冲突", tone="alarm")
                elif "superseded" in events:
                    self.entry("求援", "旧事件被新编号替代", event_id=events["superseded"],
                               status="替代", tone="warn")
            else:
                events = self.alarm.on_rescue(message, now)
                if "resolved" in events:
                    event = events["resolved"]
                    self.entry("恢复", f"告警解除（{event.reason}）", event_id=message.data["id"],
                               floor=event.floor, status="已解除", tone="ok")
                    self.notice("告警已解除，演示保持暂停", "ok")
            return

        if message.kind in ("status", "comm"):
            events = self.alarm.on_status(message, now)
            if "acked" in events:
                event = events["acked"]
                self.entry("确认", "设备已接受接收确认，告警仍然有效", event_id=event.id,
                           floor=event.floor, status="已确认", tone="ok")
            elif "timeout" in events:
                event = events["timeout"]
                self.entry("确认", "设备报告确认超时，可重新发送", event_id=event.id,
                           floor=event.floor, status="超时", tone="warn")
            elif "resolved" in events:
                self.entry("恢复", "查询显示告警已解除", event_id=message.data["id"],
                           status="已解除", tone="ok")

    # ------------------------------------------------------------------
    def _schedule(self, now: float):
        if self.transport is None or self.scheduler is None:
            return

        # 自动确认（仅专家页显式开启）
        if self.next_ack_at is not None and now >= self.next_ack_at:
            self.next_ack_at = None
            self._ack(now, automatic=True)

        if self.demo.state == RUNNING:
            self._drive_demo(now)

        if now - self.last_poll >= (POLL_ALARM if self._alarm_active() else POLL_NORMAL):
            self.last_poll = now
            if self._alarm_active():
                self.scheduler.enqueue("rescue", P.cmd_query("rescue"), PRIO_POLL,
                                       coalesce="rescue")
            elif self.caps & P.CAP_STAT:
                self.scheduler.enqueue("stat", P.cmd_query("stat"), PRIO_POLL, coalesce="stat")
            else:
                self.scheduler.enqueue("elev", P.cmd_query("elev"), PRIO_POLL, coalesce="elev")

        for result, label in self.scheduler.poll(now):
            if result == "tx-ok":
                if label.startswith("floor:") and self.demo.state == RUNNING:
                    self._demo_sent_at = now
                    self.demo.deadline = now + self.demo.period
                    # OK 之后立即查询应用结果，避免恰好错过轮询而额外等两秒。
                    name = "stat" if self.caps & P.CAP_STAT else "elev"
                    self.scheduler.enqueue(name, P.cmd_query(name), PRIO_POLL, coalesce=name)
                if label.startswith("ack:"):
                    self.alarm.mark_sent(now)
                    self.entry("确认", "ACK 已完整写出，等待设备回执", event_id=label[4:],
                               status="已发送", tone="warn")
                    self.scheduler.enqueue("rescue", P.cmd_query("rescue"), PRIO_POLL,
                                           coalesce="rescue")

            elif result == "tx-fail":
                self._write_failed(label)
            elif result == "timeout":
                self._command_timeout(label, now)

        # 链路看门狗
        last = self.state.last_valid
        if last and now - last > STALE_S:
            if self.link == "online":
                self.link = "fault"
                self.demo.pause("link")
                self.entry("链路", f"超过 {STALE_S:.0f}s 无有效回包", status="通信异常", tone="warn")
                self.notice("通信异常：演示已暂停，等待状态查询恢复", "warn")

    def _alarm_active(self) -> bool:
        event = self.alarm.current
        return bool(event and not event.resolved)

    def _drive_demo(self, now: float):
        """每个演示步只在成功进入调度队列后记一次，事务忙时下个循环重试，不重复下发。"""
        if self._alarm_active() or self.state.alert.value:
            self.demo.pause("alarm")
            self.scheduler.discard_prefix("floor:")
            return
        if not self.state.control_ready(now):
            self.demo.pause("link")
            self.scheduler.discard_prefix("floor:")
            return
        # 本步命令实际写出后才接受状态回读，旧快照和 OK 不能替代。
        sent_at = getattr(self, "_demo_sent_at", None)
        if (self._sent_step == self.demo.step and sent_at is not None and
                self.state.floor.ts > sent_at):
            self.demo.applied(self.state.floor.value, self.state.direction.value)
        if self.demo.state == COMPLETED:
            self.entry("演示", f"已到达 {self.demo.end_floor} 层，单程演示完成",
                       status="已到达", tone="ok")
            return
        if (self.demo.pending_target is not None and sent_at is not None and
                now - sent_at > STALE_S):
            self.demo.pause("link")
            self.entry("演示", "目标楼层未得到匹配回读，演示已暂停", status="回读超时", tone="warn")
            return
        target = self.demo.tick(now)
        if target is not None:
            self._sent_step = None
            self._demo_sent_at = None
        if self._sent_step == self.demo.step or not self.demo.last_target:
            return
        room, direction = self.demo.last_target
        if self._queue_floor(room, direction, "C", now, quiet=True):
            self._sent_step = self.demo.step
            # 从实际写出时刻重新计时，避免忙时补发造成连续快跑
            self.demo.deadline = max(self.demo.deadline, now + self.demo.period)

    def _queue_floor(self, floor: int, direction: str, door: str, now: float,
                     quiet: bool = False) -> bool:
        if self.transport is None or self.scheduler is None:
            return False
        if not self.secure_ready or self._alarm_active() or not self.state.control_ready(now):
            if not quiet:
                self.notice("有效告警或状态未同步，已拒绝楼层写入", "warn")
            return False
        text = f"{int(floor):02d}"
        try:
            payload = P.cmd_floor(text, direction, door)
        except P.ProtocolError as error:
            self.notice(str(error), "warn")
            return False
        label = f"floor:{text}{direction}"
        if self.scheduler.busy() or self.scheduler.has_control():
            return False
        self.scheduler.enqueue(label, payload, PRIO_CONTROL)
        if not quiet:
            self.entry("命令", f"手动下发 {text} 层 · {P.DIRECTION_TEXT[direction]} · "
                               f"{P.DOOR_TEXT[door]}", status="待回执", tone="mute")
        return True

    def _write_failed(self, label: str):
        if label.startswith("raw:SUB="):
            self.emit({"kind": "subtitle_feedback", "note": "串口写入失败，字幕状态未知。"})
        if label.startswith("ack:"):
            self.alarm.mark_failed(self.clock(), "串口写入失败")
        if label.startswith(("floor:", "raw:", "ack:")) or label == "alert":
            self._renew_secure_session("写入结果不确定")
        elif label == "hello":
            self.secure_ready = False
        self.notice(f"命令 {label} 写入失败，已停止后续自动发送", "error")
        self.demo.pause("link")

    def _renew_secure_session(self, reason: str):
        if self.scheduler is None:
            return
        self.secure_ready = False
        self.secure = P.SecureSession()
        self.scheduler.clear(PRIO_DEBUG)
        self.scheduler.active = None
        self.scheduler.enqueue("hello", self.secure.frame("HELLO", hello=True), PRIO_CONTROL)
        self.scheduler.enqueue("rescue", P.cmd_query("rescue"), PRIO_POLL, coalesce="rescue")
        self.scheduler.enqueue("elev", P.cmd_query("elev"), PRIO_POLL, coalesce="elev")
        self.entry("会话", f"{reason}，重新建立受保护会话", status="重同步", tone="warn")

    def _command_timeout(self, label: str, now: float):
        if label.startswith("raw:SUB="):
            self.emit({"kind": "subtitle_feedback", "note": "设备未在时限内回复，字幕状态未知。"})
        if label.startswith("floor:") or label in ("alert",) or label.startswith("raw:"):
            self._renew_secure_session("控制回执超时")
        if label.startswith("raw:"):
            self.entry("串口", f"{label[4:]} 未收到预期回执，结果未确认",
                       status="未确认", tone="warn")
            self.notice("原始命令未收到预期回执，请查看 RX 记录", "warn")
            return
        if label in ("info", "stat"):
            self.caps = 0
            self.entry("查询", f"{label.upper()}? 未回应，继续 ELEV? 查询",
                       status="只读", tone="warn")
            self.notice("扩展查询未回应，继续使用 ELEV?", "warn")
            return
        if label.startswith("ack:"):
            self.alarm.mark_failed(now, "写入后无回执")
        self.demo.pause("link")
        self.entry("超时", f"{label} 未在 500ms 内回执，演示暂停", status="超时", tone="warn")
        self.notice("命令超时：已暂停演示，改用状态查询重新同步", "warn")

    # ------------------------------------------------------------------
    def _start_demo(self, now: float, start_floor: int = 1, end_floor: int = 5,
                    mode: str = "roundtrip"):
        if self.transport is None:
            self.notice("未连接，不能开始演示", "warn")
            return
        if self._alarm_active():
            self.notice("存在有效告警，先处理告警", "warn")
            return
        if not self.state.control_ready(now):
            self.notice("等待新鲜楼层与告警回读，暂不能开始演示", "warn")
            return
        if self.demo.state == RUNNING or self.demo.state.startswith("PAUSED"):
            self.notice("请先停止当前演示，再修改起止楼层", "warn")
            return
        try:
            self.demo.start(now, start_floor, end_floor, mode)
        except ValueError as error:
            self.notice(str(error), "warn")
            return
        if self.state.known_floor() != start_floor:
            self.entry("初始化", f"从 {start_floor} 层开始演示；实际楼层等待设备回读",
                       status="待下发", tone="warn")
        self.scheduler.discard_prefix("floor:")
        self._sent_step = None
        self._demo_sent_at = None
        route = self.demo.snapshot(now)["route"]
        direction = "上行" if end_floor > start_floor else "下行"
        self.entry("演示", f"开始 2 秒楼层演示（{route} · {direction}出发）",
                   status="运行中", tone="ok")

    def _pause_demo(self, now: float):
        if self.demo.state != RUNNING:
            return
        self.demo.pause("user")
        self.scheduler.discard_prefix("floor:")
        self._queue_stop_direction(now)
        self.entry("演示", "操作者暂停，已发送同层停止方向", status="已暂停", tone="mute")

    def _resume_demo(self, now: float):
        if self.demo.state not in ("PAUSED_USER", "PAUSED_ALARM", "PAUSED_LINK"):
            return
        if self._alarm_active() or not self.state.control_ready(now):
            self.notice("有效告警或状态未同步，不能继续演示", "warn")
            return
        if not self.demo.resume(now, self.state.floor.value, self.state.direction.value):
            self.notice("楼层未知或不在本次演示区间，请停止后重新开始", "warn")
            return
        self._sent_step = self.demo.step
        self._demo_sent_at = None
        self.entry("演示", f"从 {self.state.floor.value} 层继续", status="运行中", tone="ok")

    def _stop_demo(self, now: float):
        if self.demo.state == STOPPED:
            return
        self.demo.stop()
        self.scheduler.discard_prefix("floor:")
        self._sent_step = None
        self._queue_stop_direction(now)
        self.entry("演示", "演示停止，设备楼层保持不变", status="已停止", tone="mute")

    def _queue_stop_direction(self, now: float):
        room = self.state.known_floor()
        if room is None or self.transport is None:
            return
        if self._alarm_active() and self.state.alert.value and not (self.caps & P.CAP_FLOOR):
            return
        self._queue_floor(room, "S", "C", now, quiet=True)

    def _manual(self, command: dict, now: float):
        if self.transport is None:
            self.notice("未连接，不能下发", "warn")
            return
        if self._alarm_active() or not self.state.control_ready(now):
            self.notice("有效告警或状态未同步，不能下发楼层", "warn")
            return
        self.demo.stop()
        self.scheduler.discard_prefix("floor:")
        self._sent_step = None
        if not self._queue_floor(int(command.get("floor", 1)), command.get("direction", "S"),
                                 command.get("door", "C"), now, quiet=False):
            self.notice("串口事务在途，本次下发已忽略", "warn")
            self.entry("命令", "手动下发被忽略：串口事务在途", status="未发送", tone="warn")

    def _demo_alert(self, on: bool, now: float):
        if self.transport is None or not self.secure_ready:
            self.notice("未连接", "warn")
            return
        self.demo.pause("alarm")
        self.scheduler.discard_prefix("floor:")
        self.scheduler.discard_prefix("raw:")
        try:
            frame = P.cmd_alert(on)
        except P.ProtocolError as error:
            self.notice(str(error), "warn")
            return
        self.scheduler.enqueue("alert", frame, PRIO_CONTROL)
        self.entry("演练", "触发串口演示告警" if on else "解除串口演示告警",
                   status="已发送", tone="warn")

    # ------------------------------------------------------------------
    def _ack(self, now: float, automatic: bool = False):
        if not self.secure_ready:
            return False
        ok, reason = self.alarm.request_ack(now, journal_ok=not (self.journal and self.journal.failed))
        if not ok:
            self.notice(reason, "warn")
            self.entry("确认", reason, status="拒绝", tone="warn")
            return False
        event = self.alarm.current
        try:
            frame = P.cmd_ack(event.id)
        except P.ProtocolError as error:
            self.alarm.mark_failed(now, str(error))
            self.notice(str(error), "error")
            return False
        self.scheduler.enqueue(f"ack:{event.id}", frame, PRIO_ACK, expects=False)
        self.entry("确认", f"发送 ACK={event.id}" + ("（专家页自动）" if automatic else "（人工）"),
                   event_id=event.id, floor=event.floor, status="确认中", tone="alarm")
        return True

    def _query(self, name: str):
        if self.scheduler is None:
            return
        priority = PRIO_POLL if name != "boot" else PRIO_DEBUG
        self.scheduler.enqueue(name, P.cmd_query(name), priority)

    def _raw_send(self, text: str, now: float):
        """调试输入也由唯一串口线程调度；ACK 仍经过告警确认生命周期。"""
        def result(accepted: bool, note: str):
            self.emit({"kind": "raw_send_result", "accepted": accepted,
                       "text": text, "note": note})
            if not accepted:
                self.notice(note, "warn")

        try:
            payload = P.cmd_raw(text)
        except P.ProtocolError as error:
            result(False, str(error))
            return
        if self.transport is None or self.scheduler is None:
            result(False, "未连接，命令未发送")
            return
        body = payload[:-2].decode("ascii")
        upper = body.upper()
        if upper.startswith("SUB=") and not self.secure_ready:
            result(False, "安全会话尚未建立，字幕命令未发送")
            return
        if upper in ("INFO?", "STAT?") and not getattr(self.transport, "sim", False):
            result(False, "当前硬件未实现 INFO?/STAT?，请用 ELEV?/RESCUE?/BOOT?")
            return
        if upper.startswith("ACK="):
            event = self.alarm.current
            if event is None or event.resolved or upper != f"ACK={event.id}":
                result(False, "ACK 编号必须匹配当前有效求援事件")
                return
            accepted = self._ack(now)
            result(accepted, "ACK 已交由优先确认队列处理" if accepted else "当前事件不能提交 ACK，请查看告警状态")
            return
        if upper in ("ALERT=ON", "ALERT=OFF"):
            if self.scheduler.has_control():
                result(False, "串口控制事务在途，请稍后重试")
                return
            self._demo_alert(upper == "ALERT=ON", now)
            result(True, "告警命令已进入发送队列")
            return
        queries = {"ELEV?": "elev", "RESCUE?": "rescue", "BOOT?": "boot",
                   "INFO?": "info", "STAT?": "stat"}
        if self.scheduler.size() >= 20:
            result(False, "发送队列已满，请等待当前事务完成")
            return
        if upper in queries:
            name = queries[upper]
            accepted = self.scheduler.enqueue(name, payload, PRIO_POLL, coalesce=name)
        else:
            is_query = upper.endswith("?") and upper[:-1].replace("_", "").isalnum()
            if not is_query:
                if self._alarm_active() or self.state.alert.value:
                    result(False, "有效告警期间请使用查询、匹配 ACK 或 ALERT=OFF")
                    return
                if upper.startswith(("ELEV=", "FLOOR=")) and not self.state.control_ready(now):
                    result(False, "楼层状态尚未同步，楼层写入未发送")
                    return
                if self.scheduler.has_control():
                    result(False, "串口事务在途，请稍后重试控制命令")
                    return
                self.demo.pause("user")
                self.scheduler.discard_prefix("floor:")
            response = {"VOL": "vol", "BRT": "brt", "PRD": "prd", "PIC": "pic"}.get(
                upper.split("=", 1)[0].rstrip("?"))
            accepted = self.scheduler.enqueue(
                f"raw:{body}", payload, PRIO_DEBUG if is_query else PRIO_CONTROL,
                coalesce=f"raw:{body}",
                replies=("ok", response) if response else ("ok",))
        result(accepted, "已排队，实际发送见 TX 记录" if accepted else "相同命令已在等待队列")
        if accepted:
            self.entry("串口", f"手动发送：{body}", status="待发送", tone="mute")

    def _sim(self, action: str):
        if self.transport is not None and getattr(self.transport, "sim", False):
            getattr(self.transport, action)()
        else:
            self.notice("模拟动作仅在模拟设备下可用", "warn")

    # ------------------------------------------------------------------
    def _write(self, data: bytes):
        if self.transport is None:
            raise OSError("未连接")
        body = data[:-2].decode("ascii") if data.endswith(b"\r\n") else ""
        if body.startswith("@"):
            if not body.endswith("*"+f"{P.crc16_ccitt_false(body.rsplit('*',1)[0].encode('ascii')):04X}") or ":0000:HELLO*" not in body:
                raise OSError("仅允许 HELLO 作为会话首帧")
            wire_data = data
        elif body in ("BOOT?", "RESCUE?", "ELEV?", "SUB?") or (
                getattr(self.transport, "sim", False) and body in ("INFO?", "STAT?")):
            wire_data = data
        elif body.startswith(("FLOOR=", "ALERT=", "ACK=", "SUB=")):
            if not self.secure_ready:
                raise OSError("安全会话尚未建立，拒绝写入")
            wire_data = self.secure.frame(body)
        else:
            raise OSError("旧版或未知写命令已禁用")
        self.transport.write(wire_data)
        text = wire_data.decode("ascii", "replace").replace("\r\n", "")
        self.state.tx_lines += 1
        self._log({"dir": "tx", "kind": "cmd", "raw": text, "session": self.state.session,
                   "note": ""})
        self.emit({"kind": "raw", "dir": "tx", "text": text, "tag": "tx",
                   "clock": time.strftime("%H:%M:%S")})

    def _log(self, entry: dict):
        if self.journal is None:
            return
        try:
            self.journal.write(entry)
        except Exception as error:
            self.journal.failed = True
            self.alarm.block("日志写入失败")
            self.notice(f"日志写入失败：{error}", "error")

    def _link_lost(self, reason: str):
        self.entry("链路", reason, status="断开", tone="warn")
        self.notice(reason, "error")
        self._disconnect("链路中断")

    # ------------------------------------------------------------------
    def _publish(self, now: float):
        if now - self.last_publish < PUBLISH:
            return
        self.last_publish = now
        device = self.state.snapshot(now)
        link_age = device["link_age"]
        if self.transport is None:
            link_state = "offline"
        elif link_age == float("inf"):
            link_state = "online" if now - self.connect_ts < STALE_S else "fault"
        else:
            link_state = "online" if link_age <= STALE_S else "fault"
        self.emit({
            "kind": "snapshot",
            "ts": now,
            "link": {
                "state": link_state,
                "port": self.port,
                "sim": bool(self.transport and getattr(self.transport, "sim", False)),
                "age": None if link_age == float("inf") else link_age,
                "fresh": link_age != float("inf") and link_age <= FRESH_S,
                "timeouts": self.scheduler.timeouts if self.scheduler else 0,
                "busy": self.scheduler.busy() if self.scheduler else False,
                "queued": self.scheduler.size() if self.scheduler else 0,
            },
            "device": device,
            "alarm": self.alarm.snapshot(now),
            "stats": {"total": self.alarm.total_events, "acked": self.alarm.acked_events},
            "demo": self.demo.snapshot(now),
            "caps": self.caps,
            "auto_ack": self.auto_ack,
            "journal": {
                "path": str(self.log_path),
                "count": self.journal.count if self.journal else 0,
                "failed": bool(self.journal and self.journal.failed),
            },
        })

    def _shutdown(self):
        if self.transport is not None:
            self._disconnect("程序退出")
