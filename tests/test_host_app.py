"""上位机核心测试：协议、状态、告警、演示、调度与一次模拟设备闭环。不打开真实串口。"""
import queue
import sys
import time
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from host_app import protocol as P
from host_app.alarm import AlarmManager
from host_app.core import HostCore
from host_app.demo import COMPLETED, DemoController, PAUSED_USER, RUNNING, STOPPED
from host_app.scheduler import PRIO_ACK, PRIO_CONTROL, PRIO_POLL, Scheduler
from host_app.state import DeviceState
from host_app.transport import SimulatedTransport

def rescue_crc(body):
    return f"{body}*{P.crc16_ccitt_false(body.encode('ascii')):04X}"

REPORT = rescue_crc("RESCUE,ID=0001,A=1,F=05,D=U,DO=C,S=L,E=00")


def rescue(**kw):
    fields = dict(id="0001", active=True, floor="05", direction="U", door="C",
                  source="L", error="00")
    fields.update(kw)
    return P.Message("rescue", "", fields)


class ProtocolTests(unittest.TestCase):
    def test_subtitle_text_and_secure_simulator(self):
        self.assertEqual(P.cmd_subtitle("Hello 123"), b"SUB=HELLO 123\r\n")
        self.assertEqual(P.cmd_subtitle("123456789012"), b"SUB=123456789012\r\n")
        for text in ("", "1234567890123", "中文", "a\nb", "ON", "off", "cn", "save", "ON ", "A@B"):
            with self.subTest(text=text), self.assertRaises(P.ProtocolError):
                P.cmd_subtitle(text)
        sim = SimulatedTransport()
        sim.write(b"SUB=HELLO\r\n")
        self.assertEqual(sim._subtitle, "")
        session = P.SecureSession(0x1234ABCD)
        sim.write(session.frame("HELLO", hello=True))
        sim.write(session.frame("SUB=HELLO 123"))
        self.assertEqual(sim._subtitle, "HELLO 123")
        self.assertFalse(sim._subtitle_on)
        sim.write(session.frame("SUB=ON"))
        self.assertTrue(sim._subtitle_on)
        sim.write(session.frame("SUB=OFF"))
        self.assertFalse(sim._subtitle_on)

    def test_secure_session_crc_sequence_and_overflow(self):
        session=P.SecureSession(0x1234ABCD)
        self.assertEqual(session.frame("HELLO",hello=True),b"@1234ABCD:0000:HELLO*9228\r\n")
        self.assertEqual(session.frame("FLOOR=F05,D=U,DO=C"),
                         b"@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF9\r\n")
        with self.assertRaises(P.ProtocolError):
            session.frame("X"*21)
        self.assertEqual(session.seq,1)
        self.assertEqual(P.parse_line(REPORT[:-1]+"0").kind,"invalid")

    def test_simulator_rejects_old_and_corrupt_writes(self):
        sim=SimulatedTransport()
        sim.write(b"ALERT=ON\r\n")
        self.assertFalse(sim._alert)
        sim.write(b"@1234ABCD:0000:HELLO*9228\r\n")
        sim.write(b"@1234ABCD:0001:ALERT=ON*3133\r\n")
        self.assertFalse(sim._alert)
        sim.write(b"@1234ABCD:0001:ALERT=ON*3132\r\n")
        self.assertTrue(sim._alert)

    def test_rescue_fields(self):
        message = P.parse_line(REPORT)
        self.assertEqual(message.kind, "rescue")
        self.assertEqual(message.data["id"], "0001")
        self.assertEqual(message.data["floor"], "05")
        self.assertTrue(message.data["active"])

    def test_status_and_stat(self):
        status = P.parse_line(rescue_crc("RESCUE,ID=0001,A=1,C=ACKED"))
        self.assertEqual((status.kind, status.data["state"]), ("status", "ACKED"))
        stat = P.parse_line("STAT,F=05,D=U,DO=C,A=1,S=L,C=WAIT,I=0002,E=07,M=1F")
        self.assertEqual(stat.kind, "stat")
        self.assertEqual(stat.data["pic_mask"], 0x1F)
        self.assertEqual(stat.data["error"], "07")

    def test_invalid_and_unknown_are_not_guessed(self):
        self.assertEqual(P.parse_line("RESCUE,ID=12,A=1").kind, "invalid")
        self.assertEqual(P.parse_line("hello").kind, "unknown")
        self.assertEqual(P.parse_line("STAT,F=05,D=X").kind, "invalid")

    def test_boot_and_info(self):
        boot = P.parse_line("BOOT,SD=0065,SC=00DC,P1=033E,TF=0352,P5=05DC,V=1F")
        self.assertEqual(boot.data["tf_ms"], 850)
        self.assertEqual(boot.data["valid"], 0x1F)
        info = P.parse_line("INFO,P=11,FW=0001,HW=EG4S20,CAP=0007")
        self.assertEqual(info.data["caps"], 0x0007)

    def test_commands(self):
        self.assertEqual(P.cmd_ack("0001"), b"ACK=0001\r\n")
        self.assertEqual(P.cmd_floor("5", "U", "C"), b"FLOOR=F05,D=U,DO=C\r\n")
        with self.assertRaises(P.ProtocolError):
            P.cmd_elev("B1", "D", "O")
        with self.assertRaises(P.ProtocolError):
            P.cmd_floor("0", "X", "C")

    def test_floor_index_ignores_unknown(self):
        self.assertEqual(P.floor_index("05"), 5)
        self.assertIsNone(P.floor_index("--"))
        self.assertIsNone(P.floor_index("B1"))

    def test_raw_frame_limits_and_no_multiline_injection(self):
        self.assertEqual(P.cmd_raw(" ELEV? "), b"ELEV?\r\n")
        self.assertEqual(P.cmd_raw("SUB=ON"), b"SUB=ON\r\n")
        for text in ("", "   ", "X" * 40, "X" * 41, "中文", "ELEV?\nALERT=OFF",
                     "ELEV?\r\n", "A\tB", "A\x00B", None):
            with self.subTest(text=text), self.assertRaises(P.ProtocolError):
                P.cmd_raw(text)


class StateTests(unittest.TestCase):
    def test_actual_boot_reply_is_received_but_not_a_known_floor(self):
        state = DeviceState()
        msg = P.parse_line("ELEV=F00,D=S,DO=M,A=0")
        self.assertEqual(msg.kind, "elev")
        state.apply(msg, 100.0)
        snap = state.snapshot(100.1)
        self.assertTrue(snap["status_received"])
        self.assertFalse(snap["known"])
        self.assertEqual(snap["floor"], "00")
        self.assertEqual(snap["direction"], "S")
        self.assertEqual(snap["door"], "M")
        self.assertTrue(state.control_ready(100.1))
        self.assertFalse(state.control_ready(107.0))
        state.apply(P.parse_line("ELEV=F00,D=S,DO=M,A=1"), 108.0)
        self.assertFalse(state.control_ready(108.1))

    def test_display_floor_is_independent_of_demo_range(self):
        for floor in ("B1", "06", "99"):
            state = DeviceState()
            state.apply(P.parse_line(f"ELEV=F{floor},D=D,DO=C,A=0"), 10.0)
            self.assertTrue(state.snapshot(10.1)["known"])
            self.assertIsNone(state.known_floor())

    def test_rescue_does_not_overwrite_floor(self):
        state = DeviceState(lambda: 100.0)
        state.apply(P.parse_line("ELEV=F03,D=D,DO=O,A=0"), 100.0)
        state.apply(P.parse_line(REPORT), 101.0)
        self.assertEqual(state.floor.value, "03")
        self.assertTrue(state.alert.value)
        self.assertEqual(state.alert.source, "rescue")

    def test_unknown_text_does_not_refresh_link(self):
        state = DeviceState(lambda: 10.0)
        state.apply(P.parse_line(rescue_crc("RESCUE,ID=0001,A=1,C=ACKED")), 10.0)
        before = state.last_valid
        state.apply(P.parse_line("garbage echo"), 12.0)
        self.assertEqual(state.last_valid, before)

    def test_field_age_marks_stale(self):
        state = DeviceState(lambda: 0.0)
        state.apply(P.parse_line("ELEV=F02,D=S,DO=C,A=0"), 1.0)
        snapshot = state.snapshot(9.0)
        self.assertEqual(snapshot["floor_age"], 8.0)
        self.assertTrue(snapshot["known"])


class AlarmTests(unittest.TestCase):
    def setUp(self):
        self.alarm = AlarmManager()
        self.now = 100.0

    def test_new_event_and_duplicate(self):
        self.alarm.on_rescue(rescue(), self.now)
        events = self.alarm.on_rescue(rescue(), self.now + 0.2)
        self.assertIn("repeat", events)
        self.assertEqual(self.alarm.current.count, 2)
        self.assertEqual(self.alarm.total_events, 1)

    def test_conflict_blocks_ack(self):
        self.alarm.on_rescue(rescue(), self.now)
        self.alarm.on_rescue(rescue(floor="03"), self.now + 0.2)
        self.assertTrue(self.alarm.current.conflict)
        ok, reason = self.alarm.request_ack(self.now, journal_ok=True)
        self.assertFalse(ok)
        self.assertIn("冲突", reason)

    def test_ack_requires_device_confirmation(self):
        self.alarm.on_rescue(rescue(), self.now)
        ok, _ = self.alarm.request_ack(self.now, journal_ok=True)
        self.assertTrue(ok)
        self.assertEqual(self.alarm.current.ack, "sending")
        self.alarm.mark_sent(self.now + 0.1)
        self.assertEqual(self.alarm.current.ack, "sent")
        self.alarm.on_status(P.Message("status", "", {"id": "0001", "active": True,
                                                      "state": "ACKED"}), self.now + 0.2)
        self.assertEqual(self.alarm.current.ack, "acked")
        self.assertFalse(self.alarm.current.resolved)

    def test_new_id_supersedes_and_recovery_closes(self):
        self.alarm.on_rescue(rescue(), self.now)
        self.alarm.on_rescue(rescue(id="0002"), self.now + 1)
        self.assertEqual(self.alarm.current.id, "0002")
        events = self.alarm.on_rescue(rescue(id="0003", active=False), self.now + 2)
        self.assertIn("resolved", events)
        self.assertTrue(self.alarm.current.resolved)

    def test_journal_failure_blocks_ack(self):
        self.alarm.on_rescue(rescue(), self.now)
        ok, reason = self.alarm.request_ack(self.now, journal_ok=False)
        self.assertFalse(ok)
        self.assertIn("日志", reason)


class DemoTests(unittest.TestCase):
    def test_sequence_and_no_burst(self):
        demo = DemoController(period=2.0)
        self.assertEqual(demo.start(0.0), (1, "S"))
        self.assertIsNone(demo.tick(1.0))
        demo.applied("01", "S")
        self.assertEqual(demo.tick(2.0), (2, "U"))
        demo.applied("02", "U")
        # 迟到 5 秒只前进一步，且从当前时刻重新计时
        self.assertEqual(demo.tick(7.0), (3, "U"))
        self.assertIsNone(demo.tick(7.1))
        self.assertEqual(demo.state, RUNNING)

    def test_pause_and_resume_keeps_direction(self):
        demo = DemoController(period=2.0)
        demo.start(0.0)
        demo.pause("alarm")
        self.assertFalse(demo.resume(10.0, "--"))
        self.assertTrue(demo.resume(10.0, "03", "D"))
        self.assertEqual(demo.tick(12.0), (2, "D"))

    def test_stop_resets(self):
        demo = DemoController(period=2.0)
        demo.start(0.0)
        demo.pause("user")
        self.assertEqual(demo.state, PAUSED_USER)
        demo.stop()
        self.assertEqual(demo.state, STOPPED)
        self.assertIsNone(demo.tick(99.0))

    def test_all_custom_single_routes_wait_for_final_readback(self):
        for start in range(1, 6):
            for end in range(1, 6):
                if start == end:
                    continue
                with self.subTest(start=start, end=end):
                    demo = DemoController()
                    demo.start(0.0, start, end, "single")
                    delta = 1 if end > start else -1
                    direction = "U" if delta > 0 else "D"
                    expected = [(start, "S")] + [
                        (floor, direction) for floor in range(start + delta, end + delta, delta)
                    ] + [(end, "S")]
                    self.assertEqual(list(demo.sequence), expected)
                    self.assertIsNone(demo.tick(50.0))  # 未回读不得跳步
                    now = 0.0
                    for target in expected[:-1]:
                        demo.applied(f"{target[0]:02d}", target[1])
                        now += 2.0
                        self.assertEqual(demo.tick(now), expected[expected.index(target) + 1])
                    self.assertEqual(demo.state, RUNNING)
                    demo.applied(f"{end:02d}", direction)
                    self.assertEqual(demo.state, RUNNING)
                    demo.applied(f"{end:02d}", "S")
                    self.assertEqual(demo.state, COMPLETED)
                    self.assertIsNone(demo.tick(now + 2.0))

    def test_roundtrip_boundaries_and_direction_resume(self):
        demo = DemoController()
        demo.start(0.0, 5, 2, "roundtrip")
        expected = [(5, "S"), (4, "D"), (3, "D"), (2, "D"), (2, "S"),
                    (3, "U"), (4, "U"), (5, "U"), (5, "S")]
        self.assertEqual(list(demo.sequence), expected)
        for i, target in enumerate(expected):
            demo.applied(f"{target[0]:02d}", target[1])
            next_target = demo.tick((i + 1) * 2.0)
            self.assertEqual(next_target, expected[i + 1] if i + 1 < len(expected) else (4, "D"))
        demo.pause("user")
        self.assertFalse(demo.resume(30.0, "01"))
        self.assertTrue(demo.resume(30.0, "03", "U"))
        self.assertEqual(demo.tick(32.0), (4, "U"))
        demo.pause("alarm")
        self.assertTrue(demo.resume(40.0, "02", "S"))
        self.assertEqual(demo.tick(42.0), (3, "U"))

    def test_invalid_route_does_not_mutate_running_route(self):
        demo = DemoController()
        demo.start(0.0, 4, 2, "single")
        for start, end, mode in ((2, 2, "single"), (0, 5, "single"),
                                  (1, 6, "single"), (True, 5, "single"),
                                  ("2", 4, "single"), (1, 5, "invalid")):
            with self.assertRaises(ValueError):
                demo.start(1.0, start, end, mode)
            self.assertEqual((demo.start_floor, demo.end_floor, demo.mode), (4, 2, "single"))

    def test_pause_at_single_endpoint_still_sends_stop(self):
        demo = DemoController()
        demo.start(0.0, 2, 3, "single")
        demo.applied("02", "S")
        self.assertEqual(demo.tick(2.0), (3, "U"))
        demo.applied("03", "U")
        self.assertEqual(demo.tick(4.0), (3, "S"))
        demo.pause("alarm")
        self.assertTrue(demo.resume(10.0, "03", "U"))
        self.assertEqual(demo.state, RUNNING)
        self.assertEqual(demo.tick(12.0), (3, "S"))


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.now = 0.0
        self.scheduler = Scheduler(self.sent.append, lambda: self.now, timeout=0.5)

    def test_single_transaction_and_ack_bypass(self):
        self.scheduler.enqueue("floor:02U", b"FLOOR=F02,D=U,DO=C\r\n", PRIO_CONTROL)
        self.scheduler.enqueue("floor:03U", b"FLOOR=F03,D=U,DO=C\r\n", PRIO_CONTROL)
        self.scheduler.poll(0.0)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.scheduler.poll(0.1), [])
        self.scheduler.enqueue("ack:0001", b"ACK=0001\r\n", PRIO_ACK, expects=False)
        self.scheduler.poll(0.2)
        self.assertEqual(self.sent[-1], b"ACK=0001\r\n")
        self.assertIsNotNone(self.scheduler.active)

    def test_timeout_and_coalesce(self):
        self.scheduler.enqueue("rescue", b"RESCUE?\r\n", PRIO_POLL, coalesce="rescue")
        self.assertTrue(self.scheduler.enqueue("stat", b"STAT?\r\n", PRIO_POLL,
                                               coalesce="stat"))
        self.assertFalse(self.scheduler.enqueue("rescue", b"RESCUE?\r\n", PRIO_POLL,
                                                coalesce="rescue"))
        self.scheduler.poll(0.0)
        result = self.scheduler.poll(0.6)
        self.assertEqual(result, [("timeout", "rescue")])

    def test_reply_clears_transaction(self):
        self.scheduler.enqueue("elev", b"ELEV?\r\n", PRIO_POLL)
        self.scheduler.poll(0.0)
        self.assertEqual(self.scheduler.on_line("elev"), "elev")
        self.assertFalse(self.scheduler.busy())
        self.assertIsNone(self.scheduler.on_line("rescue"))

    def test_unrelated_reply_does_not_finish_query(self):
        self.scheduler.enqueue("info", b"INFO?\r\n", PRIO_POLL)
        self.scheduler.poll(0.0)
        self.assertIsNone(self.scheduler.on_line("elev"))
        self.assertIsNone(self.scheduler.on_line("ok"))
        self.assertTrue(self.scheduler.busy())
        self.assertEqual(self.scheduler.on_line("err"), "info")

    def test_raw_reply_types_and_cancel_preserve_ack(self):
        self.scheduler.enqueue("raw:VOL?", b"VOL?\r\n", PRIO_CONTROL, replies=("vol", "ok"))
        self.scheduler.poll(0.0)
        self.assertIsNone(self.scheduler.on_line("pic"))
        self.assertEqual(self.scheduler.on_line("vol"), "raw:VOL?")
        self.scheduler.enqueue("floor:02U", b"floor", PRIO_CONTROL)
        self.scheduler.enqueue("raw:X", b"x", PRIO_CONTROL, coalesce="raw:X")
        self.scheduler.enqueue("ack:0001", b"ack", PRIO_ACK, expects=False)
        self.scheduler.discard_prefix("floor:")
        self.scheduler.discard_prefix("raw:")
        self.assertEqual(self.scheduler.size(), 1)
        self.scheduler.poll(0.1)
        self.assertEqual(self.sent[-1], b"ack")
        self.assertTrue(self.scheduler.enqueue("raw:X", b"x", PRIO_CONTROL, coalesce="raw:X"))


class BootCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.core = HostCore(queue.Queue(), queue.Queue(), ROOT / "logs" / "unused.jsonl",
                             clock=lambda: 100.1)
        self.core.transport = object()
        self.core.scheduler = Scheduler(self.sent.append, clock=lambda: 100.1)
        self.core.secure_ready = True
        self.core._on_line(b"ELEV=F00,D=S,DO=M,A=0\r", 100.0)

    def test_explicit_demo_starts_at_one_without_inventing_readback(self):
        self.core._start_demo(100.1)
        self.core._drive_demo(100.1)
        self.core.scheduler.poll(100.1)
        self.assertEqual(self.sent, [b"FLOOR=F01,D=S,DO=C\r\n"])
        self.assertEqual(self.core.state.snapshot(100.1)["floor"], "00")
        self.assertFalse(self.core.state.snapshot(100.1)["known"])
        self.core._on_line(b"OK\r", 100.2)
        self.assertFalse(self.core.state.snapshot(100.2)["known"])
        self.core._on_line(b"ELEV=F01,D=S,DO=C,A=0\r", 100.3)
        self.assertTrue(self.core.state.snapshot(100.3)["known"])

    def test_manual_can_initialize_but_alert_blocks_all_floor_writes(self):
        self.core._manual({"floor": 3, "direction": "U", "door": "C"}, 100.1)
        self.core.scheduler.poll(100.1)
        self.assertEqual(self.sent, [b"FLOOR=F03,D=U,DO=C\r\n"])
        self.core.scheduler.on_line("ok")
        self.core._on_line(b"ELEV=F00,D=S,DO=M,A=1\r", 100.2)
        self.assertFalse(self.core._queue_floor(2, "U", "C", 100.3))
        self.core._start_demo(100.3)
        self.assertEqual(self.core.demo.state, STOPPED)
        self.core.scheduler.poll(100.3)
        self.assertEqual(len(self.sent), 1)

    def test_info_timeout_falls_back_without_pausing_valid_demo(self):
        self.core._start_demo(100.1)
        self.core._command_timeout("info", 100.2)
        self.assertEqual(self.core.caps, 0)
        self.assertEqual(self.core.demo.state, RUNNING)
        self.core.scheduler.enqueue("info", P.cmd_query("info"))
        self.core.scheduler.poll(100.2)
        self.core._on_line(b"ERR\r", 100.3)
        self.assertFalse(self.core.scheduler.busy())


class RouteAndRawCoreTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.events, self.commands = queue.Queue(), queue.Queue()
        self.core = HostCore(self.events, self.commands, ROOT / "logs" / "unused.jsonl",
                             clock=lambda: self.now)
        self.sent = []
        self.core.transport = object()
        self.core.scheduler = Scheduler(self.sent.append, clock=lambda: self.now)
        self.core.secure_ready = True
        self.core.last_poll = self.now
        self.core._on_line(b"ELEV=F00,D=S,DO=M,A=0", self.now)

    def raw_result(self):
        results = []
        while not self.events.empty():
            event = self.events.get_nowait()
            if event.get("kind") == "raw_send_result":
                results.append(event)
        self.assertTrue(results)
        return results[-1]

    def test_custom_single_route_dispatch_and_arrival_readback(self):
        self.commands.put({"op": "start", "start_floor": 4, "end_floor": 2, "mode": "single"})
        self.core._drain_commands(self.now)
        expected = [(4, "S"), (3, "D"), (2, "D"), (2, "S")]
        for i, (floor, direction) in enumerate(expected):
            self.now = 100.0 + 2 * i
            self.core.last_poll = self.now
            self.core._schedule(self.now)
            self.assertEqual(self.sent[-1],
                             f"FLOOR=F{floor:02d},D={direction},DO=C\r\n".encode())
            self.now += 0.1
            self.core._on_line(b"OK", self.now)
            self.core.scheduler.poll(self.now)  # 楼层写入后的即时回读查询
            self.assertEqual(self.sent[-1], b"ELEV?\r\n")
            self.core._drive_demo(self.now)
            self.assertEqual(self.core.demo.state, RUNNING)
            self.now += 0.1
            self.core._on_line(f"ELEV=F{floor:02d},D={direction},DO=C,A=0".encode(), self.now)
            self.core._drive_demo(self.now)
        self.assertEqual(self.core.demo.state, COMPLETED)
        self.assertEqual(len(self.sent), 8)

    def test_queued_or_stale_readback_cannot_skip_start(self):
        self.core._start_demo(self.now, 1, 3, "single")
        self.core._drive_demo(self.now)  # 已排队，尚未实际发送
        self.core._on_line(b"ELEV=F01,D=S,DO=C,A=0", self.now + 0.1)
        self.core._drive_demo(self.now + 2.0)
        self.assertEqual(self.core.demo.last_target, (1, "S"))
        self.assertEqual(self.core.demo.step, 1)
        self.assertEqual(self.core.scheduler.size(), 1)

    def test_raw_queries_frame_and_transaction_match(self):
        for text, expected, reply in (("ELEV?", b"ELEV?\r\n", "elev"),
                                      ("RESCUE?", b"RESCUE?\r\n", "status")):
            self.core._raw_send(text, self.now)
            self.assertTrue(self.raw_result()["accepted"])
            self.core.scheduler.poll(self.now)
            self.assertEqual(self.sent[-1], expected)
            self.assertIsNotNone(self.core.scheduler.on_line(reply))
        self.core._raw_send("ELEV?\nALERT=OFF", self.now)
        self.assertFalse(self.raw_result()["accepted"])
        self.assertEqual(self.core.scheduler.size(), 0)

    def test_raw_control_pauses_demo_and_offline_rejects(self):
        self.core._start_demo(self.now, 2, 4, "roundtrip")
        self.core._raw_send("SUB=ON", self.now)
        self.assertTrue(self.raw_result()["accepted"])
        self.assertEqual(self.core.demo.state, PAUSED_USER)
        self.core.scheduler.poll(self.now)
        self.assertEqual(self.sent, [b"SUB=ON\r\n"])
        self.core.transport = None
        self.core._raw_send("ELEV?", self.now)
        self.assertFalse(self.raw_result()["accepted"])

    def test_raw_ack_prioritizes_current_event_and_alarm_blocks_floor_write(self):
        self.core.scheduler.enqueue("raw:BRT=80", b"BRT=80\r\n", PRIO_CONTROL)
        self.core._on_line(REPORT.encode(), self.now + 0.1)
        self.assertEqual(self.core.scheduler.size(), 0)
        self.core._raw_send("ELEV=F02,D=U,DO=C,A=0", self.now + 0.2)
        self.assertFalse(self.raw_result()["accepted"])
        self.core._raw_send("ACK=0002", self.now + 0.2)
        self.assertFalse(self.raw_result()["accepted"])
        self.core._raw_send("ELEV?", self.now + 0.2)
        self.assertTrue(self.raw_result()["accepted"])
        self.core.scheduler.poll(self.now + 0.2)
        self.core._raw_send("ACK=0001", self.now + 0.3)
        self.assertTrue(self.raw_result()["accepted"])
        self.core.scheduler.poll(self.now + 0.3)
        self.assertEqual(self.sent, [b"ELEV?\r\n", b"ACK=0001\r\n"])
        self.assertTrue(self.core.scheduler.busy())
        self.core._raw_send("ACK=0001", self.now + 0.4)
        self.assertFalse(self.raw_result()["accepted"])

    def test_route_alarm_guard_discards_unsent_floor(self):
        self.core._start_demo(self.now, 3, 5, "roundtrip")
        self.core._drive_demo(self.now)
        self.assertEqual(self.core.scheduler.size(), 1)
        self.core._on_line(b"ELEV=F03,D=S,DO=C,A=1", self.now + 0.1)
        self.assertEqual(self.core.demo.state, "PAUSED_ALARM")
        self.assertEqual(self.core.scheduler.size(), 0)
        self.core.scheduler.poll(self.now + 0.2)
        self.assertEqual(self.sent, [])


class SimulatedLoopTests(unittest.TestCase):
    """真实线程 + 模拟设备的端到端闭环，用于防止状态机接线回归。"""

    def test_custom_down_route_and_raw_query_on_worker(self):
        events, commands = queue.Queue(), queue.Queue()
        core = HostCore(events, commands, ROOT / "logs" / "_test_host_route.jsonl")
        core.start()
        try:
            commands.put({"op": "connect", "port": "SIM-ROUTE"})
            self.wait(events, lambda s: s["device"]["known"] and s["caps"], 3.0)
            # 等启动标志建立新会话，并显式重新查询；不触碰真实串口。
            time.sleep(0.4)
            commands.put({"op": "raw_send", "text": "ELEV?"})
            self.wait(events, lambda s: s["device"]["known"], 3.0)
            core.demo.period = 0.05
            commands.put({"op": "start", "start_floor": 5, "end_floor": 2, "mode": "single"})
            snap = self.wait(events, lambda s: s["demo"]["completed"], 5.0)
            self.assertEqual(snap["device"]["floor"], "02")
            self.assertEqual(snap["device"]["direction"], "S")
            self.assertEqual(snap["demo"]["route"], "5→2")
        finally:
            core.stop_event.set()
            core.join(2.0)
        self.assertEqual(core.errors, 0)

    def test_alarm_ack_recover(self):
        events, commands = queue.Queue(), queue.Queue()
        core = HostCore(events, commands, ROOT / "logs" / "_test_host_app.jsonl")
        core.start()
        try:
            commands.put({"op": "connect", "port": "SIM-01"})
            snap = self.wait(events, lambda s: s["device"]["known"], 3.0)
            self.assertEqual(snap["device"]["floor"], "01")
            snap = self.wait(events, lambda s: s["caps"], 3.0)
            self.assertEqual(snap["caps"], P.CAP_FLOOR | P.CAP_STAT | P.CAP_INFO)

            commands.put({"op": "start"})
            snap = self.wait(events, lambda s: s["demo"]["running"], 2.0)
            self.assertTrue(snap["demo"]["running"])

            commands.put({"op": "sim_alarm"})
            snap = self.wait(events, lambda s: s["alarm"] is not None, 2.0)
            self.assertEqual(snap["alarm"]["ack"], "none")
            self.assertIn("PAUSED", snap["demo"]["state"])

            commands.put({"op": "ack"})
            snap = self.wait(events, lambda s: s["alarm"]["acked"], 2.0)
            self.assertTrue(snap["alarm"]["acked"])
            self.assertFalse(snap["alarm"]["resolved"])

            commands.put({"op": "sim_recover"})
            snap = self.wait(events, lambda s: s["alarm"]["resolved"], 2.0)
            self.assertTrue(snap["alarm"]["resolved"])
            self.assertEqual(snap["alarm"]["ack"], "acked")
        finally:
            commands.put({"op": "disconnect"})
            core.stop_event.set()
            core.join(2.0)
        self.assertEqual(core.errors, 0)

    def test_legacy_boot_zero_initializes_and_reads_back(self):
        class LegacyBootDevice(SimulatedTransport):
            def __init__(self, *args):
                super().__init__(*args)
                self._floor, self._door = 0, "M"

            def _handle(self, text):
                if text.upper() in ("INFO?", "STAT?"):
                    self._emit("ERR")
                else:
                    super()._handle(text)

        events, commands = queue.Queue(), queue.Queue()
        core = HostCore(events, commands, ROOT / "logs" / "_test_host_legacy.jsonl")
        with patch("host_app.core.SimulatedTransport", LegacyBootDevice):
            core.start()
            try:
                commands.put({"op": "connect", "port": "SIM-LEGACY"})
                snap = self.wait(events, lambda s: s["device"]["status_received"], 3.0)
                self.assertEqual(snap["device"]["floor"], "00")
                self.assertFalse(snap["device"]["known"])
                commands.put({"op": "start"})
                snap = self.wait(events, lambda s: s["device"]["known"], 4.0)
                self.assertIn(snap["device"]["floor"], ("01", "02"))
                self.assertEqual(snap["caps"], 0)
                self.assertTrue(snap["demo"]["running"])
            finally:
                core.stop_event.set()
                core.join(2.0)
        self.assertEqual(core.errors, 0)

    @staticmethod
    def wait(events, predicate, timeout):
        deadline = time.time() + timeout
        found = None
        while time.time() < deadline:
            try:
                event = events.get(timeout=0.05)
            except queue.Empty:
                continue
            if event.get("kind") == "snapshot":
                found = event
                if predicate(event):
                    return event
        raise AssertionError(f"等待条件超时，最后一次快照：{found}")


if __name__ == "__main__":
    unittest.main()
