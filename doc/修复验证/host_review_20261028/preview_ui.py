"""UI review only: isolated logs, SIM selection, no hardware connection."""
from pathlib import Path
import argparse
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
from host_app.ui import Console
from host_app import display as D

parser = argparse.ArgumentParser()
parser.add_argument("--theme", choices=("paper", "graphite"), default="graphite")
parser.add_argument("--geometry")
args = parser.parse_args()
root = D.create_root()
with patch("host_app.ui.config.load", return_value={"theme": args.theme}):
    console = Console(root, Path(__file__).parent / "ui_simulation.jsonl")
console.port.set("SIM-01 · 内置模拟设备")
root.title("梯间守望 · 圆角高清验证 · " + args.theme)
if args.geometry:
    root.after(700, lambda: root.geometry(args.geometry))
root.mainloop()
