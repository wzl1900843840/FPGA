"""梯安·灵眸演示接收端。仅接收、记录及确认，不控制电梯或图像处理。"""
from __future__ import annotations
import csv
import heapq
import json
import os
from pathlib import Path
import queue
import re
import threading
import time
import uuid
from datetime import datetime, timezone

RESCUE = re.compile(r"RESCUE,ID=([0-9A-F]{4}),A=([01]),F=(--|[0-9]{2}|B[1-9]),D=([UDS]),DO=([OCM]),S=([LUB]),E=([0-9A-F]{2})\r\n\Z")
STATUS = re.compile(r"RESCUE,ID=([0-9A-F]{4}),A=([01]),C=(IDLE|WAIT|ACKED|TIMEOUT)\r\n\Z")
BOOT = "MEDIA PLAYER READY\r\n"

def parse_rescue(raw: bytes) -> dict:
    text = raw.decode("ascii", errors="strict")
    match = RESCUE.fullmatch(text)
    if not match:
        raise ValueError("报文格式或字段无效")
    event_id, active, floor, direction, door, source, error = match.groups()
    return dict(event_id=event_id, active=int(active), floor=floor,
                direction=direction, door=door, source=source, error=error)

class Journal:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.handle = path.open("a", encoding="utf-8", buffering=1)

    def write(self, entry: dict):
        entry = dict(timestamp=datetime.now(timezone.utc).isoformat(), **entry)
        self.handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.handle.flush()
        os.fsync(self.handle.fileno())

    def close(self):
        self.handle.close()

class Receiver:
    """Single-thread protocol engine; persist before queueing an ACK."""
    def __init__(self, journal, send, notify=lambda event: None, clock=time.monotonic):
        self.journal, self.send, self.notify, self.clock = journal, send, notify, clock
        self.auto_ack, self.delay = True, 0.0
        self.session = ""
        self.seen = {}
        self.pending = []
        self.order = 0

    def new_session(self, reason):
        self.session = uuid.uuid4().hex[:12]
        self.seen.clear()
        self.pending.clear()
        self.journal.write(dict(kind="session", session=self.session, reason=reason))
        self.notify(dict(kind="session", session=self.session, reason=reason))

    def receive(self, raw: bytes):
        if raw == BOOT.encode():
            self.new_session("FPGA启动标志")
            return
        text = raw.decode("ascii", errors="replace")
        if text.startswith("RESCUE,") and ",C=" in text:
            match = STATUS.fullmatch(text)
            if match:
                event_id, active, state = match.groups()
                event = dict(kind="status", session=self.session, event_id=event_id,
                             active=int(active), state=state, raw=text)
                self.journal.write(event)
                self.notify(event)
                return
        if not text.startswith("RESCUE,"):
            event = dict(kind="text", session=self.session, raw=text)
            self.journal.write(event)
            self.notify(event)
            return
        try:
            fields = parse_rescue(raw)
        except (UnicodeError, ValueError) as error:
            event = dict(kind="invalid", session=self.session, raw=text, error=str(error))
            self.journal.write(event)
            self.notify(event)
            return
        key = fields["event_id"]
        duplicate = key in self.seen
        if duplicate and self.seen[key] != fields:
            event = dict(kind="invalid", session=self.session, raw=text, error="同会话同编号内容冲突")
            self.journal.write(event)
            self.notify(event)
            return
        event = dict(kind="rescue", session=self.session, duplicate=duplicate, **fields)
        # A persistence error propagates; no ACK can be emitted on failed logging.
        self.journal.write(event)
        self.seen[key] = fields
        self.notify(event)
        if not fields["active"]:
            self.pending.clear()
        elif self.auto_ack:
            if not duplicate:
                self.pending.clear()
            self.order += 1
            heapq.heappush(self.pending, (self.clock()+self.delay, self.order, self.session, key))

    def poll(self):
        while self.pending and self.pending[0][0] <= self.clock():
            _, _, session, event_id = heapq.heappop(self.pending)
            if session != self.session or not self.auto_ack:
                continue
            self.send(f"ACK={event_id}\r\n".encode("ascii"))
            event = dict(kind="ack_sent", session=session, event_id=event_id)
            self.journal.write(event)
            self.notify(event)

def export_log(source: Path, destination: Path):
    with source.open(encoding="utf-8") as stream, destination.open("w", encoding="utf-8-sig", newline="") as target:
        columns = ["timestamp", "session", "kind", "event_id", "active", "floor", "direction", "door", "source", "error", "duplicate", "state", "raw"]
        writer = csv.DictWriter(target, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for line in stream:
            writer.writerow(json.loads(line))

class SerialWorker(threading.Thread):
    def __init__(self, port, events, commands, log_path):
        super().__init__(daemon=True)
        self.port, self.events, self.commands, self.log_path = port, events, commands, log_path
        self.stop_event = threading.Event()

    def run(self):
        import serial
        journal = None
        try:
            journal = Journal(self.log_path)
            with serial.Serial(self.port, 115200, timeout=0.03, write_timeout=1) as connection:
                def send(data):
                    if connection.write(data) != len(data):
                        raise OSError("串口写入不完整")
                    connection.flush()
                engine = Receiver(journal, send, self.events.put)
                engine.new_session("串口连接")
                self.events.put(dict(kind="connected", port=self.port))
                buffer = bytearray()
                overflow = False
                while not self.stop_event.is_set():
                    while not self.commands.empty():
                        command = self.commands.get_nowait()
                        if command[0] == "settings":
                            engine.auto_ack, engine.delay = command[1:]
                            if not engine.auto_ack:
                                engine.pending.clear()
                        elif command[0] == "query":
                            send(command[1].encode("ascii")+b"\r\n")
                    for byte in connection.read(256):
                        if len(buffer) < 512:
                            buffer.append(byte)
                        else:
                            overflow = True
                        if byte == 10:
                            if overflow:
                                journal.write(dict(kind="invalid", session=engine.session, error="报文超过512字节"))
                                self.events.put(dict(kind="invalid", error="报文超过512字节"))
                            else:
                                engine.receive(bytes(buffer))
                            buffer.clear()
                            overflow = False
                    engine.poll()
        except Exception as error:
            self.events.put(dict(kind="error", error=str(error)))
        finally:
            if journal:
                journal.close()
            self.events.put(dict(kind="disconnected"))

class App:
    def __init__(self, root):
        import tkinter as tk
        from tkinter import ttk
        self.root, self.worker = root, None
        self.events, self.commands = queue.Queue(), queue.Queue()
        self.log_path = Path(__file__).resolve().parents[1]/"logs/rescue_receiver.jsonl"
        self.root.title("梯安·灵眸 · 应急联动接收端")
        self.root.geometry("1050x570")
        self.port = tk.StringVar()
        self.auto = tk.BooleanVar(value=True)
        self.delay = tk.StringVar(value="0")
        self.state = tk.StringVar(value="未连接")
        self.session = tk.StringVar(value="会话：未建立")
        bar = ttk.Frame(root, padding=12)
        bar.pack(fill="x")
        self.ports = ttk.Combobox(bar, textvariable=self.port, width=16, state="readonly")
        self.ports.pack(side="left")
        for title, action in [("刷新串口", self.refresh), ("连接", self.connect), ("断开", self.disconnect)]:
            ttk.Button(bar, text=title, command=action).pack(side="left", padx=4)
        ttk.Checkbutton(bar, text="自动确认", variable=self.auto, command=self.settings).pack(side="left", padx=8)
        ttk.Label(bar, text="确认延迟(秒)").pack(side="left")
        ttk.Spinbox(bar, from_=0, to=30, increment=0.1, textvariable=self.delay, width=6).pack(side="left")
        ttk.Button(bar, text="应用", command=self.settings).pack(side="left", padx=4)
        ttk.Label(root, textvariable=self.state, padding=8).pack(anchor="w")
        ttk.Label(root, textvariable=self.session, padding=8).pack(anchor="w")
        columns = ("event", "floor", "direction", "door", "source", "error", "state", "repeats")
        self.table = ttk.Treeview(root, columns=columns, show="headings", height=10)
        for column, title in zip(columns, ["事件编号", "楼层", "方向", "门状态", "来源", "故障码", "通信状态", "重复接收"]):
            self.table.heading(column, text=title)
            self.table.column(column, width=100 if column!="state" else 230, anchor="center")
        self.table.pack(fill="both", expand=True, padx=12)
        bottom = ttk.Frame(root, padding=12)
        bottom.pack(fill="x")
        for title, command in [("查询救援状态", "RESCUE?"), ("查询楼层", "ELEV?")]:
            ttk.Button(bottom, text=title, command=lambda c=command:self.commands.put(("query", c))).pack(side="left", padx=4)
        ttk.Button(bottom, text="导出日志CSV", command=self.export).pack(side="left", padx=4)
        ttk.Label(bottom, text="确认表示接收端已记录请求；不代表救援已到场。").pack(side="right")
        self.notes = tk.Text(root, height=6, state="disabled")
        self.notes.pack(fill="x", padx=12, pady=(0,12))
        self.rows = {}
        self.refresh()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(50, self.drain)

    def refresh(self):
        from serial.tools import list_ports
        ports = [p.device for p in list_ports.comports()]
        self.ports["values"] = ports
        if ports and self.port.get() not in ports:
            self.port.set(ports[0])

    def settings(self):
        from tkinter import messagebox
        try:
            delay = float(self.delay.get())
            if not 0<=delay<=30:
                raise ValueError()
        except ValueError:
            messagebox.showerror("参数无效", "确认延迟必须在0至30秒之间")
            return False
        self.commands.put(("settings", self.auto.get(), delay))
        return True

    def connect(self):
        if self.worker and self.worker.is_alive():
            return
        if not self.port.get() or not self.settings():
            return
        self.worker = SerialWorker(self.port.get(), self.events, self.commands, self.log_path)
        self.worker.start()

    def disconnect(self):
        if self.worker:
            self.worker.stop_event.set()

    def export(self):
        from tkinter import filedialog, messagebox
        destination = filedialog.asksaveasfilename(defaultextension=".csv", filetypes=[("CSV", "*.csv")])
        if destination:
            try:
                export_log(self.log_path, Path(destination))
            except Exception as error:
                messagebox.showerror("导出失败", str(error))

    def drain(self):
        labels = dict(IDLE="空闲", WAIT="等待接收确认", ACKED="接收端已确认", TIMEOUT="通信未确认")
        while not self.events.empty():
            event = self.events.get_nowait()
            kind = event["kind"]
            if kind == "session":
                self.session.set("会话："+event["session"]+" · "+event["reason"])
            elif kind == "connected":
                self.state.set("已连接 "+event["port"]+" · 115200 8N1")
            elif kind in ("disconnected", "error"):
                self.state.set("连接异常："+event["error"] if kind=="error" else "已断开")
            elif kind == "rescue":
                key = event["session"]+":"+event["event_id"]
                if not event["active"]:
                    for previous_key, row in self.rows.items():
                        if previous_key.startswith(event["session"]+":"):
                            self.table.set(row, "state", "告警已解除")
                if key in self.rows:
                    values = list(self.table.item(self.rows[key], "values"))
                    values[-1] = int(values[-1])+1
                    self.table.item(self.rows[key], values=values)
                else:
                    values = (event["event_id"], event["floor"], dict(U="上行",D="下行",S="停止")[event["direction"]],
                              dict(O="开门",C="关门",M="运动/未知")[event["door"]], dict(L="本地",U="串口",B="双来源")[event["source"]],
                              event["error"], "请求已发送（FPGA上报）" if event["active"] else "告警已解除", 0)
                    self.rows[key] = self.table.insert("", "end", values=values)
            elif kind in ("ack_sent", "status"):
                key = event["session"]+":"+event["event_id"]
                if key in self.rows:
                    self.table.set(self.rows[key], "state", "接收端已确认（ACK已回传）" if kind=="ack_sent" else labels[event["state"]])
            self.notes.configure(state="normal")
            self.notes.insert("end", json.dumps(event, ensure_ascii=False)+"\n")
            if int(self.notes.index("end-1c").split(".")[0])>500:
                self.notes.delete("1.0", "100.0")
            self.notes.see("end")
            self.notes.configure(state="disabled")
        self.root.after(50, self.drain)

    def close(self):
        self.disconnect()
        if self.worker and self.worker.is_alive():
            self.root.after(50, self.close)
        else:
            self.root.destroy()

if __name__ == "__main__":
    import tkinter as tk
    root = tk.Tk()
    App(root)
    root.mainloop()
