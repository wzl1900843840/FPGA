"""Construct and exercise Tk presentation without opening a physical UART."""
import importlib.util
import queue
from pathlib import Path
import tempfile
import tkinter as tk

root_path = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receiver", root_path / "tools/rescue_receiver.py")
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)
root = tk.Tk()
root.withdraw()
app = receiver.App(root)
app.events.put(dict(kind="session", session="synthetic", reason="test"))
event = dict(kind="rescue", session="synthetic", event_id="0001", active=True,
             floor="05", direction="U", door="C", source="L", error="00")
app.events.put(event)
app.drain()
row = app.rows["synthetic:0001"]
assert "请求已发送" in app.table.set(row, "state")
app.events.put(dict(kind="ack_sent", session="synthetic", event_id="0001"))
app.drain()
assert "ACK已回传" in app.table.set(row, "state")
app.events.put(dict(event, event_id="0002", active=False))
app.drain()
assert app.table.set(row, "state") == "告警已解除"
app.events.put(dict(kind="boot_metrics",session="synthetic",sd_ms=100,scan_ms=200,pic1_ms=800,tf_ms=820,pic5_ms=1400,valid=31))
app.drain()
assert "内部TF首像素=820ms" in app.boot_state.get()
root.update_idletasks()
root.update()
root.destroy()
print("PASS receiver Tk: widgets, enumeration, event loop, event/ACK/clear presentation; board not connected")
