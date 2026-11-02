"""梯间守望上位机启动入口。

用法：D:/Anaconda/python.exe tools/stairwell_watch.py
依赖：Python 标准库 Tkinter；连接实板另需 pyserial（tools/requirements-rescue.txt）。
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from host_app.ui import launch  # noqa: E402

if __name__ == "__main__":
    launch(HERE.parent / "logs" / "host_console.jsonl")
