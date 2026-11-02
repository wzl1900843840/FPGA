"""Read-only host review probes: fake transport only; never opens a COM port."""
from __future__ import annotations

import json
import queue
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from host_app import protocol as P
from host_app.core import HostCore
from host_app.scheduler import Scheduler, PRIO_ACK, PRIO_CONTROL
from host_app.transport import SimulatedTransport


class MemoryJournal:
    failed = False
    count = 0
    def __init__(self):
        self.rows = []
    def write(self, entry):
        self.rows.append(entry)
        self.count += 1
    def close(self):
        pass


class MemoryTransport:
    sim = False
    def __init__(self):
        self.sent = []
    def write(self, data):
        self.sent.append(data.decode('ascii').strip())
    def read(self, size=256):
        return b''
    def close(self):
        pass


def make_core():
    core = HostCore(queue.Queue(), queue.Queue(), ROOT / 'logs' / 'NOT_OPENED.jsonl', clock=lambda: 10.0)
    core.transport = MemoryTransport()
    core.journal = MemoryJournal()
    core.scheduler = Scheduler(core._write, clock=lambda: 10.0)
    core.link = 'online'
    core.connect_ts = 9.0
    core.last_poll = 10.0
    core.state.new_session('review', 9.0)
    return core


def alarm(core):
    core._on_line(b'RESCUE,ID=0001,A=1,F=03,D=U,DO=C,S=U,E=00', 10.0)


results = []

c = make_core()
c._on_line(b'RESCUE,ID=0001,A=1,C=TIMEOUT', 10.0)
c._on_line(b'ELEV=F03,D=U,DO=C,A=1', 10.0)
allowed = c._queue_floor(4, 'U', 'C', 10.0)
c.scheduler.poll(10.0)
results.append(dict(case='active_alarm_reconnect', alarm_object=c.alarm.current is not None,
                    device_alert=c.state.alert.value, floor_allowed=allowed, sent=c.transport.sent))

c = make_core()
c._queue_floor(4, 'U', 'C', 10.0)
alarm(c)
c._schedule(10.0)
results.append(dict(case='alarm_does_not_cancel_queued_floor',
                    current_alarm=c._alarm_active(), sent=c.transport.sent))

c = make_core()
alarm(c)
old_session = c.state.session
c._ack(10.0)
c.scheduler.enqueue('floor:04U', P.cmd_elev('04', 'U', 'C'), PRIO_CONTROL)
c.caps = 7
c._on_line(P.READY.encode('ascii'), 10.1)
c._schedule(10.1)
results.append(dict(case='ready_does_not_invalidate_old_commands', new_session=c.state.session != old_session,
                    old_alarm_remains=c._alarm_active(), retained_caps=c.caps, sent=c.transport.sent))

sent = []
s = Scheduler(sent.append)
s.enqueue('floor:04U', P.cmd_elev('04', 'U', 'C'))
s.poll(10.0)
matched = s.on_line(P.parse_line('ERR 87').kind)
results.append(dict(case='system_error_consumes_command_transaction', matched=matched, active=s.active is not None))

c = make_core()
alarm(c)
c.replaying = True
c._ack(10.0)
c._schedule(10.0)
results.append(dict(case='core_replay_flag_does_not_block_tx', sent=c.transport.sent))

c = make_core()
c.auto_ack = True
c.ack_delay = 2.0
alarm(c)
c.commands.put(dict(op='settings', auto_ack=False, ack_delay=2.0))
c._drain_commands(10.5)
c._schedule(12.0)
results.append(dict(case='disable_auto_ack_leaves_timer', auto_ack=c.auto_ack, sent=c.transport.sent))

c = make_core()
alarm(c)
c._on_line(b'STAT,F=03,D=U,DO=C,A=0,S=N,C=IDLE,I=0001,E=00,M=1F', 11.0)
results.append(dict(case='stat_recovery_not_applied_to_alarm_manager',
                    device_alert=c.state.alert.value, alarm_active=c._alarm_active()))

c = make_core()
c._on_line(b'ELEV=F03,D=U,DO=C,A=0', 1.0)
c.link = 'fault'
allowed = c._queue_floor(4, 'U', 'C', 20.0)
c.scheduler.poll(20.0)
results.append(dict(case='stale_link_does_not_block_control', link=c.link,
                    field_age=20.0-c.state.floor.ts, allowed=allowed, sent=c.transport.sent))

c = make_core()
alarm(c)
c._ack(10.0)
c._schedule(10.0)
results.append(dict(case='human_ack_not_structured_in_journal',
                    persisted_kinds=[row.get('kind') for row in c.journal.rows],
                    click_recorded=any('点击' in str(row) or row.get('kind')=='ack_requested' for row in c.journal.rows)))

t = SimulatedTransport()
t._out = [(0.0, b'X' * 300)]
first = t.read(256)
second = t.read(256)
results.append(dict(case='simulator_read_drops_remaining_bytes', first_bytes=len(first), second_bytes=len(second),
                    lost_bytes=300-len(first)-len(second)))

c = make_core()
c._on_line(b'ELEV=F03,D=U,DO=C,A=0', 10.0)
alarm(c)
c._ack(10.0)
c._schedule(10.0)
c._on_line(b'RESCUE,ID=0001,A=1,C=ACKED', 10.1)
c._on_line(b'RESCUE,ID=0002,A=0,F=03,D=U,DO=C,S=U,E=00', 11.0)
results.append(dict(case='normal_manual_ack_and_clear_control', ack=c.alarm.current.ack,
                    resolved=c.alarm.current.resolved, sent=c.transport.sent))

print(json.dumps(dict(scope='fake transport only; no serial port or FPGA actions', results=results),
                 ensure_ascii=False, indent=2))
