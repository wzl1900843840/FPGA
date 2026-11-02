"""Inspect native Tk geometry without desktop automation or serial access."""
from pathlib import Path
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
from host_app import display as D
from host_app import theme as T
from host_app.ui import Console

root = D.create_root()
try:
    with patch("host_app.ui.HostCore"), patch("host_app.ui.config.load", return_value={"theme": "graphite"}):
        app = Console(root, Path(__file__).with_suffix(".jsonl"))
        for width, height, scale in ((1920, 1080, 1.0), (2400, 1260, 1.25), (1280, 860, 1.0)):
            with patch.object(D, "window_dpi", return_value=round(96 * scale)):
                D.configure(root)
                app._rebuild()
                root.minsize(D.px(T.WIN_MIN_W), D.px(T.WIN_MIN_H))
                root.geometry(f"{width}x{height}+0+0")
                root.update_idletasks()
                app._fit_layout()
                root.update_idletasks()
                print("viewport", root.winfo_width(), root.winfo_height(), "scale", scale)
                for name in ("btn_start", "btn_manual", "target_line", "tree", "btn_present"):
                    widget = getattr(app, name)
                    clips = []
                    parent = widget.master
                    x0, y0 = widget.winfo_rootx(), widget.winfo_rooty()
                    x1, y1 = x0 + widget.winfo_width(), y0 + widget.winfo_height()
                    while parent is not None:
                        px, py = parent.winfo_rootx(), parent.winfo_rooty()
                        if x0 < px - 2 or y0 < py - 2 or x1 > px + parent.winfo_width() + 2 or y1 > py + parent.winfo_height() + 2:
                            clips.append(str(parent))
                        parent = parent.master
                    print(name, widget.winfo_width(), widget.winfo_height(), "clips", clips)
finally:
    for job in root.tk.call("after", "info"):
        root.tk.call("after", "cancel", job)
    root.destroy()
