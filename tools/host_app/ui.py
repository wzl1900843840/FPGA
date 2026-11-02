"""主窗口：固定告警带 + 井道看板 + 演示控制 + 诊断页签 + 状态栏。"""
from __future__ import annotations

import collections
import queue
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

from . import config
from . import display as D
from . import journal as J
from . import protocol as P
from . import theme as T
from .core import HostCore
from .widgets import (AgeBar, FlatButton, FloorTrace, RoundedPanel, RoundedSelect, ScrollablePage, ShaftView, SignalBars,
                      Switch, TabBar, ThemeSwatches, hairline, vline)

TABS = ("事件时间线", "原始串口", "启动计时", "历史回放", "专家测试", "字幕发布")
BOOT_NODES = (
    ("sd_ms", "初始化就绪"),
    ("scan_ms", "扫描完成"),
    ("pic1_ms", "PIC1 校验"),
    ("tf_ms", "内部首像素"),
    ("pic5_ms", "PIC5 就绪"),
)


class Console:
    def __init__(self, root: tk.Tk, log_path: Path):
        self.prefs = config.load()
        T.apply(self.prefs.get("theme", T.DEFAULT))
        self.root = root
        D.configure(root)
        self.log_path = Path(log_path)
        self.entries: list[dict] = []
        self.raw_lines: collections.deque = collections.deque(maxlen=600)
        self.events: queue.Queue = queue.Queue(maxsize=20000)
        self.commands: queue.Queue = queue.Queue()
        self.core = HostCore(self.events, self.commands, self.log_path)
        self.snap: dict = {}
        self.replay = False
        self.presentation = False
        self._layout_job = None
        self._compact = None
        self._dpi_job = None
        self._manual_dir_buttons = {}
        self._manual_door_buttons = {}
        self._replay_content = ""
        self._replay_name = ""
        self.rows = 0
        self._pulse = 0
        self._band_color = T.SURFACE
        self._band_active = None

        self.port = tk.StringVar(value="")
        self.link_text = tk.StringVar(value="未连接")
        self.link_sub = tk.StringVar(value="选择串口后连接 · 115200 8N1")
        self.band_title = tk.StringVar(value="无有效告警")
        self.band_id = tk.StringVar(value="")
        self.band_meta = tk.StringVar(value="系统处于监视状态")
        self.band_state = tk.StringVar(value="")
        self.count_text = tk.StringVar(value="0 条")
        self.status_left = tk.StringVar(value="RX 0 · TX 0 · 无效 0")
        self.status_mid = tk.StringVar(value="等待连接")
        self.status_right = tk.StringVar(value=str(self.log_path))
        self.demo_note = tk.StringVar(value="1↔5 · 往返 · 每 2 秒一层")
        self.demo_start_floor = tk.StringVar(value="1")
        self.demo_end_floor = tk.StringVar(value="5")
        self.demo_mode = tk.StringVar(value="往返")
        self.raw_command = tk.StringVar(value="ELEV?")
        self.raw_send_note = tk.StringVar(value="单行 ASCII · 自动追加 CRLF · 最长 40 字节")
        self.raw_history = []
        self._raw_pending = False
        self._subtitle_pending = False
        self.subtitle_text = tk.StringVar(value="WELCOME")
        self.subtitle_note = tk.StringVar(value="连接设备后输入字幕；开启字幕需要单独操作")
        self.boot_note = tk.StringVar(value="尚未查询 · 以复位释放为起点")

        self._build_styles()
        self._build_shell()
        self._build_topbar()
        self._build_band()
        self._build_main()
        self._build_status()
        self._build_tabs()
        self._apply_view_mode()
        self._bind_keys()
        self.refresh_ports()

        self.core.start()
        T.apply_window_chrome(self.root)
        self.root.after(50, self._drain)
        self.root.after(140, self._tick)
        self.root.after(820, self._pulse_tick)

    # ==================================================================
    # 外观
    # ==================================================================
    def _build_styles(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("S.Treeview", background=T.PANEL, fieldbackground=T.PANEL,
                        foreground=T.TEXT_2, borderwidth=0, rowheight=D.px(36),
                        font=D.font((T.UI, T.F_LABEL)))
        style.configure("S.Treeview.Heading", background=T.PANEL_TOP, foreground=T.TEXT_3,
                        borderwidth=0, relief="flat", font=D.font((T.UI, T.F_MICRO)),
                        padding=D.px((12, 10)))
        style.map("S.Treeview", background=[("selected", T.PANEL_HI)],
                  foreground=[("selected", T.TEXT)])
        style.map("S.Treeview.Heading", background=[("active", T.PANEL_TOP)])
        style.layout("S.Treeview", [("Treeview.treearea", {"sticky": "nswe"})])
        style.configure("S.Vertical.TScrollbar", background=T.LINE, troughcolor=T.SURFACE,
                        bordercolor=T.SURFACE, arrowcolor=T.TEXT_3, width=D.px(10),
                        arrowsize=D.px(10), relief="flat")
        style.configure("S.TCombobox", font=D.font((T.UI, T.F_LABEL)),
                        fieldbackground=T.PANEL_HI, background=T.PANEL_HI,
                        foreground=T.TEXT, arrowcolor=T.TEXT_2, bordercolor=T.LINE,
                        lightcolor=T.PANEL_HI, darkcolor=T.PANEL_HI,
                        selectbackground=T.PANEL_HI, selectforeground=T.TEXT,
                        padding=D.px((12, 8)), relief="flat")
        self.root.option_add("*TCombobox*Listbox.font", D.font((T.UI, T.F_LABEL)))
        style.map("S.TCombobox",
                  fieldbackground=[("readonly", T.PANEL_HI)],
                  bordercolor=[("focus", T.JADE_DIM), ("hover", T.HOVER_BORDER)])
        for option, color in (("background", T.PANEL_HI), ("foreground", T.TEXT),
                              ("selectBackground", T.JADE_DIM),
                              ("selectForeground", T.TEXT)):
            self.root.option_add(f"*TCombobox*Listbox.{option}", color)

    def _build_shell(self):
        self.root.configure(bg=T.BG)
        self.root.title("梯间守望 · 上位机控制台")
        screen_w, screen_h = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        width = min(D.px(T.WIN_W), screen_w - D.px(48))
        height = min(D.px(T.WIN_H), screen_h - D.px(80))
        left = max(0, (screen_w - width) // 2)
        top = max(0, (screen_h - height) // 2 - 24)
        self._placement = f"{width}x{height}+{left}+{top}"
        self.root.geometry(self._placement)
        self.root.minsize(min(D.px(T.WIN_MIN_W), width), min(D.px(T.WIN_MIN_H), height))
        self.root.bind("<Configure>", self._queue_layout, add="+")
        self.root.after(90, self._keep_on_screen)
        self.root.after(600, self._keep_on_screen)

    def _keep_on_screen(self):
        """系统可能沿用上次窗口位置，确保标题栏与状态栏都不会落到屏幕外。"""
        screen_w, screen_h = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        x, y = self.root.winfo_rootx(), self.root.winfo_rooty()
        width, height = self.root.winfo_width(), self.root.winfo_height()
        if x < 0 or y < 0 or x + width > screen_w or y + height > screen_h - 40:
            self.root.geometry(self._placement)

    # ------------------------------------------------------------------
    def _build_topbar(self):
        bar = D.Frame(self.root, height=T.TOPBAR_H, bg=T.SURFACE)
        self.topbar = bar
        bar.pack(fill="x")
        bar.pack_propagate(False)

        mark = D.Canvas(bar, width=26, height=26, bg=T.SURFACE, highlightthickness=0)
        mark.place(x=20, y=21)
        for index in range(3):
            mark.create_rectangle(index * 5, 20 - index * 6, index * 5 + 3, 20, fill=T.JADE)
        mark.create_rectangle(15, 5, 25, 20, outline=T.TEXT_3, fill="")

        D.Label(bar, text="梯间守望", bg=T.SURFACE, fg=T.TEXT,
                 font=(T.UI, -27, "bold")).place(x=58, y=10)
        D.Label(bar, text="电梯信息发布与应急联动 · 设备控制台", bg=T.SURFACE,
                 fg=T.TEXT_3, font=(T.UI, -14)).place(x=59, y=48)
        self.environment_tag = D.Label(bar, text="离线待连接", bg=T.PANEL_HI,
                                        fg=T.TEXT_2, padx=10, pady=4,
                                        font=(T.UI, -12, "bold"))
        self.environment_tag.place(x=190, y=15)

        right = D.Frame(bar, bg=T.SURFACE)
        right.pack(side="right", padx=(0, 24), pady=16)

        self.port_box = D.Combobox(right, textvariable=self.port, width=18,
                                     state="readonly", style="S.TCombobox",
                                     font=(T.UI, T.F_LABEL))
        self.port_box.pack(side="left")
        self.btn_connect = FlatButton(right, "连接设备", self.toggle_connect, width=100, height=42,
                                      kind="primary", bg=T.SURFACE)
        self.btn_connect.pack(side="left", padx=(8, 0))
        FlatButton(right, "刷新", self.refresh_ports, width=60, height=42, kind="quiet",
                   bg=T.SURFACE).pack(side="left", padx=(4, 0))

        vline(right, T.LINE, 1).pack(side="left", fill="y", padx=16, pady=1)

        status = D.Frame(right, bg=T.SURFACE, width=260, height=48)
        status.pack_propagate(False)
        status.pack(side="left")
        dot_row = D.Frame(status, bg=T.SURFACE)
        dot_row.pack(anchor="w")
        self.link_dot = D.Canvas(dot_row, width=8, height=8, bg=T.SURFACE,
                                  highlightthickness=0)
        self.link_dot.pack(side="left", pady=(0, 1))
        self.link_dot.create_oval(0, 0, 7, 7, fill=T.TEXT_4, outline="")
        D.Label(dot_row, textvariable=self.link_text, bg=T.SURFACE, fg=T.TEXT,
                 font=(T.UI, T.F_LABEL)).pack(side="left", padx=(6, 0))
        self.signal = SignalBars(dot_row, bg=T.SURFACE)
        self.signal.pack(side="left", padx=(8, 0))
        D.Label(status, textvariable=self.link_sub, bg=T.SURFACE, fg=T.TEXT_3,
                 font=(T.UI, -12)).pack(anchor="w", pady=(2, 0))

        hairline(self.root, T.LINE).pack(fill="x")

    # ------------------------------------------------------------------
    def _build_band(self):
        band = D.Frame(self.root, height=T.ALARM_H, bg=T.SURFACE)
        band.pack(fill="x")
        band.pack_propagate(False)
        self.band = band
        self.band_accent = D.Frame(band, width=4, bg=T.LINE)
        self.band_accent.place(x=0, y=0, relheight=1)

        left = D.Frame(band, bg=T.SURFACE)
        left.place(x=24, rely=0.5, anchor="w")
        self.band_left = left
        top = D.Frame(left, bg=T.SURFACE)
        top.pack(anchor="w")
        self.band_title_label = D.Label(top, textvariable=self.band_title, bg=T.SURFACE,
                                         fg=T.TEXT_2, font=(T.UI, -26, "bold"))
        self.band_title_label.pack(side="left")
        self.band_id_label = D.Label(top, textvariable=self.band_id, bg=T.SURFACE,
                                      fg=T.VERM, font=(T.NUM_MID, -24))
        self.band_id_label.pack(side="left", padx=(12, 0))
        self.band_meta_label = D.Label(left, textvariable=self.band_meta, bg=T.SURFACE,
                                        fg=T.TEXT_4, font=(T.UI, T.F_LABEL),
                                        wraplength=720, justify="left")
        self.band_meta_label.pack(anchor="w", pady=(5, 0))

        right = D.Frame(band, bg=T.SURFACE)
        right.place(relx=1.0, x=-20, rely=0.5, anchor="e")
        self.band_right = right
        self.band_state_label = D.Label(right, textvariable=self.band_state, bg=T.SURFACE,
                                         fg=T.TEXT_2, font=(T.UI, T.F_LABEL))
        self.band_state_label.pack(anchor="e", pady=(0, 8))
        self.band_actions = D.Frame(right, bg=T.SURFACE)
        self.band_actions.pack(anchor="e")
        self.btn_ack = FlatButton(self.band_actions, "收到响应 · ACK", self.send_ack, width=176,
                                  height=48, kind="danger",
                                  font=(T.UI, T.F_LABEL, "bold"), bg=T.SURFACE)
        self.btn_ack.pack(side="left")
        self.btn_details = FlatButton(self.band_actions, "事件详情", self.show_events, width=96,
                                      height=48, kind="ghost", bg=T.SURFACE)
        self.btn_details.pack(side="left", padx=(8, 0))
        self.flow_labels = []
        flow = D.Frame(left, bg=T.SURFACE)
        flow.pack(anchor="w", pady=(8, 0))
        for text in ("01  设备告警", "02  接收确认", "03  设备回执"):
            label = D.Label(flow, text=text, bg=T.SURFACE, fg=T.TEXT_4,
                             font=(T.UI, -14))
            label.pack(side="left", padx=(0, 22))
            self.flow_labels.append(label)

        self._band_parts = [band, left, top, right, self.band_actions,
                            self.band_title_label, self.band_meta_label,
                            self.band_state_label, self.band_id_label, flow, *self.flow_labels]
        hairline(self.root, T.LINE).pack(fill="x")

    # ------------------------------------------------------------------
    def _build_main(self):
        main = D.Frame(self.root, height=T.MAIN_H, bg=T.BG)
        self.main = main
        main.pack(fill="x")
        main.pack_propagate(False)
        main.grid_propagate(False)
        main.columnconfigure(0, minsize=340, weight=2)
        main.columnconfigure(1, minsize=840, weight=5)
        main.rowconfigure(0, weight=1)

        shaft_card, head, body = self._card(main, "电梯运行")
        shaft_card.grid(row=0, column=0, sticky="nsew", padx=(20, 8), pady=(14, 14))
        self.shaft = ShaftView(body, width=280, height=286, bg=T.PANEL)
        self.shaft.pack(fill="both", expand=True)
        self.shaft_note = D.Label(head, text="", bg=T.PANEL, fg=T.TEXT_4,
                                   font=(T.UI, T.F_MICRO))
        self.shaft_note.pack(side="right")

        right = D.Frame(main, bg=T.BG)
        right.grid(row=0, column=1, sticky="nsew", padx=(8, 20), pady=(14, 14))
        right.columnconfigure(0, weight=1)
        self.main_right = right
        right.rowconfigure(0, minsize=208, weight=0)
        right.rowconfigure(1, weight=1)
        self._build_readback(right)

        bottom = D.Frame(right, bg=T.BG)
        self.control_row = bottom
        bottom.grid(row=1, column=0, sticky="nsew", pady=(12, 0))
        bottom.columnconfigure(0, weight=1, uniform="controls")
        bottom.columnconfigure(1, weight=1, uniform="controls")
        bottom.rowconfigure(0, weight=1)
        self._build_demo(bottom)
        self._build_manual(bottom)

    def _card(self, parent, title, subtitle=""):
        outer = RoundedPanel(parent, fill=T.PANEL, border=T.LINE, radius=18, inset=10)
        head = D.Frame(outer.content, bg=T.PANEL)
        head.pack(fill="x", padx=12, pady=(8, 0))
        D.Label(head, text=title, bg=T.PANEL, fg=T.TEXT_2,
                 font=(T.UI, T.F_H2, "bold")).pack(side="left")
        if subtitle:
            label = D.Label(head, text=subtitle, bg=T.PANEL, fg=T.TEXT_4,
                             font=(T.UI, T.F_MICRO))
            label.pack(side="left", padx=(10, 0))
            label._card_subtitle = True
        body = D.Frame(outer.content, bg=T.PANEL)
        body.pack(fill="both", expand=True, padx=12, pady=(12, 8))
        return outer, head, body

    # ------------------------------------------------------------------
    def _build_readback(self, parent):
        holder = D.Frame(parent, bg=T.BG, height=156)
        holder.grid(row=0, column=0, sticky="nsew")
        holder.grid_propagate(False)
        holder.pack_propagate(False)

        card, head, body = self._card(holder, "设备实时状态", "来自串口回读")
        card.pack(fill="both", expand=True)
        self.readback_tag = D.Label(head, text="未连接", bg=T.PANEL, fg=T.TEXT_4,
                                     font=(T.UI, T.F_MICRO))
        self.readback_tag.pack(side="right")

        left = D.Frame(body, bg=T.PANEL, width=152)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)
        floor_row = D.Frame(left, bg=T.PANEL)
        floor_row.pack(anchor="w")
        self.floor_label = D.Label(floor_row, text="--", bg=T.PANEL, fg=T.TEXT_4,
                                    font=(T.NUM, -76))
        self.floor_label.pack(side="left")
        unit = D.Frame(floor_row, bg=T.PANEL)
        unit.pack(side="left", padx=(8, 0), pady=(0, 16), anchor="s")
        D.Label(unit, text="层", bg=T.PANEL, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(anchor="w")
        self.floor_src = D.Label(unit, text="—", bg=T.PANEL, fg=T.TEXT_4,
                                  font=(T.MONO, -10))
        self.floor_src.pack(anchor="w", pady=(2, 0))
        self.target_line = D.Label(left, text="目标 —", bg=T.PANEL, fg=T.TEXT_4,
                                    font=(T.UI, T.F_MICRO), anchor="w")
        self.target_line.pack(anchor="w", pady=(2, 0))

        vline(body, T.LINE_SOFT, 1).pack(side="left", fill="y", padx=(10, 16), pady=3)

        kv = D.Frame(body, bg=T.PANEL)
        kv.pack(side="left", fill="y", pady=(3, 0))
        self.kv = {}
        self.kv_rows = []
        groups = (
            (("direction", "方向"), ("door", "门状态"), ("comm", "接收确认"), ("error", "系统故障")),
            (("alert", "告警状态"), ("mode", "演示模式"), ("fresh", "数据时效"), ("source", "状态来源")),
        )
        for group in groups:
            block = D.Frame(kv, bg=T.PANEL)
            block.pack(side="left", padx=(0, 12))
            for row, (key, caption) in enumerate(group):
                line = D.Frame(block, bg=T.PANEL)
                line.pack(anchor="w", pady=(0 if row == 0 else 6, 0))
                label = D.Frame(line, bg=T.PANEL, width=70, height=30)
                label.pack(side="left")
                label.pack_propagate(False)
                D.Label(label, text=caption, bg=T.PANEL, fg=T.TEXT_3,
                         font=(T.UI, T.F_MICRO)).pack(anchor="w")
                slot = D.Frame(line, bg=T.PANEL, width=112, height=30)
                slot.pack(side="left")
                slot.pack_propagate(False)
                value = D.Label(slot, text="—", bg=T.PANEL, fg=T.TEXT_2,
                                 font=(T.UI, T.F_BODY), anchor="w")
                value.pack(anchor="w")
                self.kv[key] = value
                self.kv_rows.append((row, line, label, slot))

        self.trace_divider = vline(body, T.LINE_SOFT, 1)
        self.trace_divider.pack(side="left", fill="y", padx=(0, 14), pady=3)

        trace_box = D.Frame(body, bg=T.PANEL)
        self.trace_box = trace_box
        trace_box.pack(side="left", fill="both", expand=True)
        D.Label(trace_box, text="楼层轨迹 · 近 30 秒", bg=T.PANEL, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(anchor="w")
        self.trace = FloorTrace(trace_box, width=120, height=74, bg=T.PANEL)
        self.trace.pack(fill="both", expand=True, pady=(2, 0))

    def _build_demo(self, parent):
        card, head, body = self._card(parent, "楼层演示")
        self.demo_card, self.demo_head, self.demo_body = card, head, body
        body.pack_configure(pady=(10, 12))
        card.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self.demo_state_label = D.Label(head, text="未运行", bg=T.PANEL, fg=T.TEXT_4,
                                         font=(T.UI, T.F_MICRO))
        self.demo_state_label.pack(side="right")

        route = D.Frame(body, bg=T.PANEL)
        self.demo_route_row = route
        route.pack(fill="x", pady=(0, 14))
        self.route_boxes = []
        self.route_labels = []
        for label, variable in (("起点", self.demo_start_floor), ("终点", self.demo_end_floor)):
            caption = D.Label(route, text=label, bg=T.PANEL, fg=T.TEXT_2,
                              font=(T.UI, T.F_LABEL))
            caption.pack(side="left", padx=(0, 4))
            self.route_labels.append(caption)
            box = RoundedSelect(route, textvariable=variable, values=(1, 2, 3, 4, 5),
                                width=64, height=38, font=(T.UI, T.F_LABEL))
            box.pack(side="left", padx=(0, 8))
            box.bind("<<ComboboxSelected>>", lambda _e: self._route_changed())
            self.route_boxes.append(box)
        mode_box = RoundedSelect(route, textvariable=self.demo_mode, values=("单程", "往返"),
                                 width=104, height=38, font=(T.UI, T.F_LABEL))
        mode_box.pack(side="left", fill="x", expand=True)
        mode_box.bind("<<ComboboxSelected>>", lambda _e: self._route_changed())
        self.route_boxes.append(mode_box)

        row = D.Frame(body, bg=T.PANEL)
        self.demo_button_row = row
        row.pack(fill="x")
        self.btn_start = FlatButton(row, "开始演示", self.start_demo, 90, 38,
                                    kind="primary", font=(T.UI, T.F_LABEL, "bold"))
        self.btn_pause = FlatButton(row, "暂停", lambda: self.send({"op": "pause"}), 64, 38)
        self.btn_resume = FlatButton(row, "继续", lambda: self.send({"op": "resume"}), 64, 38)
        self.btn_stop = FlatButton(row, "停止", lambda: self.send({"op": "stop"}), 64, 38)
        for index, button in enumerate((self.btn_start, self.btn_pause,
                                        self.btn_resume, self.btn_stop)):
            row.columnconfigure(index, weight=1, uniform="demo")
            button.grid(row=0, column=index, sticky="ew", padx=(0 if index == 0 else 8, 0))

        self.demo_bar = AgeBar(body, height=3, bg=T.PANEL)
        self.demo_bar.configure(width=10)
        self.demo_bar.pack(fill="x", pady=(12, 0))
        self.demo_note_label = D.Label(body, textvariable=self.demo_note, bg=T.PANEL, fg=T.TEXT_3,
                                       font=(T.UI, T.F_MICRO))
        self.demo_note_label.pack(anchor="w", pady=(8, 0))

    def _build_manual(self, parent):
        card, head, body = self._card(parent, "手动场景", "演示输入 · 与自动互斥")
        card.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        D.Label(head, text="互斥", bg=T.PANEL, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="right")

        floors = D.Frame(body, bg=T.PANEL)
        floors.pack(fill="x")
        self.manual_floor = 1
        self.floor_buttons = {}
        for index in range(5):
            floor = index + 1
            floors.columnconfigure(index, weight=1, uniform="floor")
            button = FlatButton(floors, str(floor), lambda f=floor: self.pick_floor(f),
                                width=32, height=36, kind="ghost",
                                font=(T.NUM_MID, -18))
            button.grid(row=0, column=index, sticky="ew", padx=(0 if index == 0 else 6, 0))
            self.floor_buttons[floor] = button

        row = D.Frame(body, bg=T.PANEL)
        row.pack(side="bottom", fill="x")
        self.manual_dir = tk.StringVar(value="S")
        self.manual_door = tk.StringVar(value="C")
        dirs = D.Frame(row, bg=T.PANEL)
        dirs.pack(side="left")
        for value, glyph in (("U", "▲"), ("S", "■"), ("D", "▼")):
            button = FlatButton(dirs, glyph, lambda v=value: self.pick_dir(v), 30, 34, "ghost",
                                font=(T.UI, -12))
            button.pack(side="left", padx=(0, 4))
            self._manual_dir_buttons[value] = button
        doors = D.Frame(row, bg=T.PANEL)
        doors.pack(side="left", padx=(8, 0))
        for value, text in (("O", "开门"), ("C", "关门")):
            button = FlatButton(doors, text, lambda v=value: self.pick_door(v), 46, 34, "ghost",
                                font=(T.UI, T.F_MICRO))
            button.pack(side="left", padx=(0, 4))
            self._manual_door_buttons[value] = button
        self.btn_manual = FlatButton(row, "下发", self.send_manual, 60, 34, "wire",
                                     font=(T.UI, T.F_MICRO, "bold"))
        self.btn_manual.pack(side="right")
        self.pick_floor(1)
        self.pick_dir("S")
        self.pick_door("C")

    # ------------------------------------------------------------------
    def _build_status(self):
        hairline(self.root, T.LINE_SOFT).pack(side="bottom", fill="x")
        bar = D.Frame(self.root, height=T.STATUS_H, bg=T.BG)
        bar.pack(side="bottom", fill="x")
        bar.pack_propagate(False)
        D.Label(bar, textvariable=self.status_left, bg=T.BG, fg=T.TEXT_3,
                 font=(T.MONO, -12)).pack(side="left", padx=(20, 0))
        D.Label(bar, textvariable=self.status_mid, bg=T.BG, fg=T.TEXT_3, width=32, anchor="w",
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(18, 0))

        FlatButton(bar, "全屏 F11", self.toggle_full, 74, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.BG).pack(side="right", padx=(0, 18), pady=4)
        self.btn_present = FlatButton(bar, "投屏模式 F8", self.toggle_presentation, 110, 28, "wire",
                                      font=(T.UI, T.F_MICRO), bg=T.BG)
        self.btn_present.pack(side="right", padx=(0, 10), pady=4)
        FlatButton(bar, "导出 CSV", self.export_csv, 74, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.BG).pack(side="right", padx=(0, 2), pady=4)

        theme_box = D.Frame(bar, bg=T.BG)
        theme_box.pack(side="right", padx=(0, 12), pady=4)
        D.Label(theme_box, text="主题", bg=T.BG, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(0, 4))
        self.theme_swatches = ThemeSwatches(theme_box, T.current().key,
                                            self.set_theme, bg=T.BG)
        self.theme_swatches.pack(side="left")
        D.Label(theme_box, text=T.current().label, bg=T.BG, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(5, 0))

        self.journal_label = D.Label(bar, textvariable=self.status_right, bg=T.BG, fg=T.TEXT_3,
                                      font=(T.UI, -12))
        self.journal_label.pack(side="right", padx=(0, 16))

    # ------------------------------------------------------------------
    def set_theme(self, key: str):
        """切主题：写回令牌 → 保存偏好 → 重建控件树（Tk 没有样式表可热更）。"""
        palette = T.apply(key)
        config.save(theme=palette.key)
        self._rebuild()
        self.status_mid.set(f"主题已切换：{palette.label} · {palette.note}")

    def _rebuild(self):
        active = self.tabbar.active if hasattr(self, "tabbar") else 0
        manual = (self.manual_floor, self.manual_dir.get(), self.manual_door.get())
        samples = list(self.trace.samples)
        auto_scroll = self.auto_scroll.get()
        auto_ack = self.snap.get("auto_ack", self.auto_switch.get())
        self._band_color = None
        self._band_active = None
        for child in self.root.winfo_children():
            child.destroy()
        self._build_styles()
        T.apply_window_chrome(self.root)
        self._build_topbar()
        self._build_band()
        self._build_main()
        self._build_status()
        self._build_tabs()
        self.pick_floor(manual[0])
        self.pick_dir(manual[1])
        self.pick_door(manual[2])
        self.trace.samples = samples
        self.trace._last = samples[-1][1] if samples else None
        self.auto_scroll.set(auto_scroll)
        self.auto_switch.set(auto_ack)
        self._switch_tab(active)
        self._restore_buffers()
        if self._replay_content:
            self.replay_list.insert("end", self._replay_content)
            self.replay_label.configure(text=self._replay_name)
        self._compact = None
        self._apply_view_mode()
        if self.snap:
            self._render()

    # ------------------------------------------------------------------
    def _build_tabs(self):
        self.tabbar = TabBar(self.root, TABS, self._switch_tab, bg=T.SURFACE,
                             height=T.TABBAR_H)
        self.tabbar.pack(fill="x")
        self.pages = D.Frame(self.root, bg=T.SURFACE)
        self.pages.pack(fill="both", expand=True)
        self.page_frames = []
        for _index in range(len(TABS)):
            frame = D.Frame(self.pages, bg=T.SURFACE)
            frame.place(x=0, y=0, relwidth=1, relheight=1)
            self.page_frames.append(frame)
        self._build_timeline(self.page_frames[0])
        self._build_raw(self.page_frames[1])
        self._build_boot(self.page_frames[2])
        self._build_replay(self.page_frames[3])
        self._build_expert(self.page_frames[4])
        self._build_subtitle(self.page_frames[5])
        self._switch_tab(0)
        self._build_presentation()

    def _build_presentation(self):
        self.presentation_panel = D.Frame(self.root, bg=T.SURFACE)
        head = D.Frame(self.presentation_panel, bg=T.SURFACE)
        head.pack(fill="x", padx=20, pady=(12, 8))
        D.Label(head, text="信息发布  →  应急提示  →  人工确认  →  解除恢复",
                 bg=T.SURFACE, fg=T.TEXT, font=(T.UI, -16, "bold")).pack(side="left")
        self.present_scope = D.Label(head, text="等待设备连接", bg=T.SURFACE, fg=T.TEXT_3,
                                      font=(T.UI, T.F_MICRO))
        self.present_scope.pack(side="right")
        strip = D.Frame(self.presentation_panel, bg=T.SURFACE)
        strip.pack(fill="x", padx=20, pady=(0, 10))
        self.present_summary = D.Label(strip, text="连接设备后开始展示", bg=T.PANEL, fg=T.TEXT_2,
                                        anchor="w", padx=16, pady=14, font=(T.UI, -15))
        self.present_summary.pack(side="left", fill="both", expand=True)
        self.present_sim = D.Frame(strip, bg=T.SURFACE)
        self.present_sim.pack(side="right", padx=(12, 0))
        self.btn_sim_alarm = FlatButton(self.present_sim, "模拟求援",
                                       lambda: self.send({"op": "sim_alarm"}),
                                       108, 46, "danger", bg=T.SURFACE)
        self.btn_sim_alarm.pack(side="left", padx=(0, 8))
        self.btn_sim_recover = FlatButton(self.present_sim, "模拟解除",
                                         lambda: self.send({"op": "sim_recover"}),
                                         108, 46, "ghost", bg=T.SURFACE)
        self.btn_sim_recover.pack(side="left")
        self.present_event = D.Label(self.presentation_panel, text="最近事件：暂无记录",
                                      bg=T.SURFACE, fg=T.TEXT_3, anchor="w",
                                      font=(T.UI, T.F_LABEL), wraplength=1100)
        self.present_event.pack(fill="x", padx=22, pady=(0, 12))

    def toggle_presentation(self):
        self.presentation = not self.presentation
        self._apply_view_mode()

    def _apply_view_mode(self):
        if self.presentation:
            self.tabbar.pack_forget()
            self.pages.pack_forget()
            self.presentation_panel.pack(fill="both", expand=True)
        else:
            self.presentation_panel.pack_forget()
            self.tabbar.pack(fill="x")
            self.pages.pack(fill="both", expand=True)
        self.btn_present.set_text("诊断模式 F8" if self.presentation else "投屏模式 F8")
        self.btn_present.set_kind("primary" if self.presentation else "wire")
        self._queue_layout()

    def show_events(self):
        self.presentation = False
        self._apply_view_mode()
        self._switch_tab(0)

    def _queue_layout(self, event=None):
        if event is not None and event.widget is not self.root:
            return
        if self._layout_job is not None:
            self.root.after_cancel(self._layout_job)
        self._layout_job = self.root.after(60, self._fit_layout)

    def _fit_layout(self):
        self._layout_job = None
        if abs(D.window_dpi(self.root) / 96.0 - D.SCALE) > 0.05:
            if self._dpi_job is None:
                self._dpi_job = self.root.after(160, self._refresh_dpi)
            return
        width, height = D.logical(self.root.winfo_width()), D.logical(self.root.winfo_height())
        compact = width < 1500 or height < 810
        tight = height < 900
        top_h, band_h = (76, 108) if tight else (T.TOPBAR_H, T.ALARM_H)
        self.topbar.configure(height=top_h)
        self.band.configure(height=band_h)
        available = height - top_h - band_h - T.STATUS_H - 2
        # 矮屏优先收敛留白，宽裕屏保留 14px 行距；字体和点击区均不缩小。
        self.demo_body.pack_configure(pady=(8, 8) if tight else (10, 12))
        self.demo_route_row.pack_configure(pady=(0, 10 if tight else 14))
        self.demo_bar.pack_configure(pady=(8 if tight else 12, 0))
        self.demo_note_label.pack_configure(pady=(6 if tight else 8, 0))
        self.band_meta_label.configure(wraplength=max(440, width - 380))
        self.present_event.configure(wraplength=max(500, width - 48))
        short = height < 930
        for row, line, label, slot in self.kv_rows:
            label.configure(height=28 if tight else 30)
            slot.configure(height=28 if tight else 30)
            line.pack_configure(pady=(0 if row == 0 else (4 if tight else 6), 0))
        readback_h = 208 if tight else (248 if self.presentation else (224 if short else 232))
        self.main_right.rowconfigure(0, minsize=readback_h)
        # 根据真实字体度量为演示卡分配高度，避免固定 MAIN_H 将新控件挤在一起。
        # 子控件高度在修改 pack 留白后仍可立即读取；不依赖尚未重算的容器 reqheight。
        demo_h = sum(D.logical(widget.winfo_reqheight()) for widget in
                     (self.demo_head, self.demo_route_row, self.demo_button_row,
                      self.demo_bar, self.demo_note_label)) + (68 if tight else 84)
        self.main_right.rowconfigure(1, minsize=demo_h + 12)
        reserve = 120 if self.presentation else T.TABBAR_H + 96
        required = readback_h + demo_h + 40
        self.main.configure(height=max(required, min(560 if self.presentation else 530, available - reserve)))
        self.floor_label.configure(font=(T.NUM, -68 if short else
                                         (-100 if self.presentation else -92)))
        self.root.minsize(min(D.px(T.WIN_MIN_W), self.root.winfo_screenwidth() - D.px(40)),
                          min(D.px(T.WIN_MIN_H), self.root.winfo_screenheight() - D.px(80)))
        if compact != self._compact:
            self._compact = compact
            if compact:
                self.trace_box.pack_forget()
                self.trace_divider.pack_forget()
                self.journal_label.pack_forget()
            else:
                self.trace_divider.pack(side="left", fill="y", padx=(0, 14), pady=3)
                self.trace_box.pack(side="left", fill="both", expand=True)
                self.journal_label.pack(side="right", padx=(0, 16))

    def _refresh_dpi(self):
        self._dpi_job = None
        D.configure(self.root)
        self._rebuild()

    def _switch_tab(self, index: int):
        self.page_frames[index].lift()
        self.tabbar.select(index)
        if index == 2:
            self._render_boot()

    def _build_timeline(self, page):
        bar = D.Frame(page, bg=T.SURFACE)
        bar.pack(fill="x", padx=20, pady=(12, 8))
        D.Label(bar, text="会话事件", bg=T.SURFACE, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(side="left")
        D.Label(bar, textvariable=self.count_text, bg=T.SURFACE, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(8, 0))
        FlatButton(bar, "导出 CSV", self.export_csv, 72, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="right")
        FlatButton(bar, "清空视图", lambda: self._timeline_clear(), 74, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="right", padx=(6, 0))

        panel = RoundedPanel(page, fill=T.PANEL, border=T.LINE, radius=16)
        panel.pack(fill="both", expand=True, padx=20, pady=(0, 14))
        wrap = panel.content
        columns = ("time", "tag", "id", "floor", "status", "text")
        self.tree = D.Treeview(wrap, columns=columns, show="headings", style="S.Treeview")
        widths = {"time": 92, "tag": 86, "id": 74, "floor": 60, "status": 100, "text": 620}
        for column, title in zip(columns, ("时刻", "类型", "编号", "楼层", "状态", "事件")):
            self.tree.heading(column, text=title, anchor="w")
            anchor = "center" if column in ("id", "floor") else "w"
            self.tree.column(column, width=widths[column], anchor=anchor,
                             stretch=(column == "text"))
        scroll = D.Scrollbar(wrap, orient="vertical", command=self.tree.yview,
                               style="S.Vertical.TScrollbar")
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.tree.tag_configure("alarm", foreground=T.VERM_SOFT)
        self.tree.tag_configure("warn", foreground=T.AMBER)
        self.tree.tag_configure("ok", foreground=T.JADE)
        self.tree.tag_configure("mute", foreground=T.TEXT_2)
        self.tree.tag_configure("replay", foreground=T.TEXT_3)
        self.tree.tag_configure("hover", background=T.PANEL_HI)
        self._hover_iid = ""
        self.tree.bind("<Motion>", self._hover_row)
        self.tree.bind("<Leave>", lambda _e: self._set_hover_row(""))
        self.empty_hint = D.Label(wrap, text="暂无事件 · 连接设备后这里会出现求援、确认与链路记录",
                                   bg=T.PANEL, fg=T.TEXT_3, font=(T.UI, T.F_LABEL))
        self.empty_hint.place(relx=0.5, rely=0.58, anchor="center")

    def _build_subtitle(self, page):
        panel = RoundedPanel(page, fill=T.PANEL, border=T.LINE, radius=16)
        panel.pack(fill="both", expand=True, padx=20, pady=16)
        body = panel.content
        D.Label(body, text="日常字幕发布", bg=T.PANEL, fg=T.TEXT,
                font=(T.UI, T.F_LABEL, "bold")).pack(anchor="w", padx=16, pady=(14, 6))
        D.Label(body, text="自定义文字：1～12 个英文字母、数字、空格或 : . , ! ? - + _ /；小写自动转大写。",
                bg=T.PANEL, fg=T.TEXT_3, font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16)
        row = D.Frame(body, bg=T.PANEL)
        row.pack(fill="x", padx=16, pady=10)
        self.subtitle_entry = D.Entry(row, textvariable=self.subtitle_text, bg=T.PANEL_HI,
                                      fg=T.TEXT, insertbackground=T.JADE, relief="flat", bd=0,
                                      font=(T.MONO, T.F_MONO))
        self.subtitle_entry.pack(side="left", fill="x", expand=True, ipady=6)
        self.subtitle_entry.bind("<Return>", lambda _e: self.send_subtitle("text"))
        self.subtitle_buttons = []
        for label, action in (("发送文字", "text"), ("显示字幕", "on"),
                              ("关闭字幕", "off"), ("内置中文", "cn")):
            button = FlatButton(row, label, lambda a=action: self.send_subtitle(a),
                                92, 34, "primary" if action == "text" else "quiet", bg=T.PANEL)
            button.pack(side="left", padx=(8, 0))
            button.set_enabled(False)
            self.subtitle_buttons.append(button)
        D.Label(body, text="内置中文为‘照片音乐’。文字发送后还需开启字幕，并将板上 SW1 拨到字幕开启位置。告警期间字幕隐藏。",
                bg=T.PANEL, fg=T.TEXT_3, wraplength=900, justify="left",
                font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16, pady=(0, 6))
        D.Label(body, textvariable=self.subtitle_note, bg=T.PANEL, fg=T.JADE,
                wraplength=900, justify="left", font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16, pady=(0, 14))

    def _build_raw(self, page):
        bar = D.Frame(page, bg=T.SURFACE)
        bar.pack(side="bottom", fill="x", padx=20, pady=(2, 4))
        self.auto_scroll = Switch(bar, True, bg=T.SURFACE)
        self.auto_scroll.pack(side="right", padx=(8, 0))
        D.Label(bar, text="自动滚动", bg=T.SURFACE, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(side="right")
        FlatButton(bar, "清屏", lambda: self.raw.delete("1.0", "end"), 54, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="right", padx=(0, 14))

        line = D.Frame(bar, bg=T.SURFACE)
        line.pack(side="left", fill="x", expand=True, padx=(0, 12))
        D.Label(line, text="TX", bg=T.SURFACE, fg=T.JADE,
                font=(T.MONO, T.F_MICRO)).pack(side="left", padx=(0, 8))
        self.raw_entry = D.Entry(line, textvariable=self.raw_command,
                                 bg=T.PANEL_HI, fg=T.TEXT, insertbackground=T.JADE,
                                 selectbackground=T.JADE_DIM, relief="flat", bd=0,
                                 highlightthickness=1, highlightbackground=T.LINE,
                                 highlightcolor=T.JADE_DIM, font=(T.MONO, T.F_MONO))
        self.raw_entry.pack(side="left", fill="x", expand=True, ipady=5)
        self.raw_entry.bind("<Return>", self.send_raw)
        self.raw_entry.bind("<KP_Enter>", self.send_raw)
        self.raw_entry.bind("<Up>", self._raw_previous)
        self.btn_raw_send = FlatButton(line, "发送", self.send_raw, 72, 34, "primary", bg=T.SURFACE)
        self.btn_raw_send.pack(side="left", padx=(8, 0))
        self.btn_raw_send.set_enabled(False)
        self.raw_entry.configure(state="disabled")
        panel = RoundedPanel(page, fill=T.STRIPE, border=T.LINE_SOFT, radius=12, inset=4)
        panel.pack(fill="both", expand=True, padx=20)
        wrap = panel.content
        self.raw = D.Text(wrap, bg=T.STRIPE, fg=T.TEXT_2, relief="flat", bd=0,
                           font=(T.MONO, T.F_MONO), wrap="none", padx=14, pady=2,
                           insertbackground=T.JADE, selectbackground=T.PANEL_TOP,
                           highlightthickness=0, height=6)
        scroll = D.Scrollbar(wrap, orient="vertical", command=self.raw.yview,
                               style="S.Vertical.TScrollbar")
        self.raw.configure(yscrollcommand=scroll.set)
        self.raw.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.raw.tag_configure("rx", foreground=T.TEXT_2)
        self.raw.tag_configure("tx", foreground=T.JADE)
        self.raw.tag_configure("bad", foreground=T.VERM_SOFT)
        self.raw.tag_configure("clock", foreground=T.TEXT_4)

    def _build_boot(self, page):
        self.boot_scroll = ScrollablePage(page)
        self.boot_scroll.pack(fill="both", expand=True)
        page = self.boot_scroll.content
        head = D.Frame(page, bg=T.SURFACE)
        head.pack(fill="x", padx=20, pady=(12, 0))
        D.Label(head, text="启动里程碑", bg=T.SURFACE, fg=T.TEXT_2,
                 font=(T.UI, T.F_LABEL, "bold")).pack(side="left")
        D.Label(head, textvariable=self.boot_note, bg=T.SURFACE, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(10, 0))
        FlatButton(head, "查询 BOOT?", lambda: self.send({"op": "query", "name": "boot"}),
                   92, 24, "quiet", font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="right")

        self.boot_canvas = D.Canvas(page, bg=T.SURFACE, highlightthickness=0, height=210)
        self.boot_canvas.pack(fill="x", padx=20, pady=(16, 0))
        D.Label(page, text="内部首像素（TF）表示芯内收到 PIC1 有效像素，不代表外接显示器已亮屏；"
                            "FFFF 为饱和值，有效位为 0 的节点不应解读为耗时。",
                 bg=T.SURFACE, fg=T.TEXT_4, font=(T.UI, T.F_MICRO),
                 justify="left").pack(anchor="w", padx=20, pady=(10, 0))
        self.boot_scroll.bind_wheel()

    def _build_replay(self, page):
        bar = D.Frame(page, bg=T.SURFACE)
        bar.pack(fill="x", padx=20, pady=(12, 6))
        self.replay_label = D.Label(bar, text="未载入", bg=T.SURFACE, fg=T.TEXT_3,
                                     font=(T.UI, T.F_MICRO))
        self.replay_label.pack(side="left")
        FlatButton(bar, "载入 JSONL", self.load_replay, 96, 24, "ghost",
                   font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="left", padx=(12, 0))
        FlatButton(bar, "退出回放", self.exit_replay, 82, 24, "quiet",
                   font=(T.UI, T.F_MICRO), bg=T.SURFACE).pack(side="left", padx=(6, 0))
        self.replay_banner = D.Label(page, text="请先断开设备，再载入历史记录。历史数据不代表设备当前状态。",
                                      bg=T.SURFACE, fg=T.TEXT_4,
                                      font=(T.UI, T.F_MICRO), justify="left")
        self.replay_banner.pack(anchor="w", padx=20, pady=(2, 6))
        panel = RoundedPanel(page, fill=T.STRIPE, border=T.LINE_SOFT, radius=16)
        panel.pack(fill="both", expand=True, padx=20, pady=(0, 14))
        wrap = panel.content
        self.replay_list = D.Text(wrap, bg=T.STRIPE, fg=T.TEXT_2, relief="flat", bd=0,
                                   font=(T.MONO, T.F_MONO), wrap="none", padx=14, pady=10,
                                   highlightthickness=0, height=6)
        scroll = D.Scrollbar(wrap, orient="vertical", command=self.replay_list.yview,
                               style="S.Vertical.TScrollbar")
        self.replay_list.configure(yscrollcommand=scroll.set)
        self.replay_list.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

    def _build_expert(self, page):
        self.expert_scroll = ScrollablePage(page)
        self.expert_scroll.pack(fill="both", expand=True)
        page = self.expert_scroll.content
        head = D.Frame(page, bg=T.SURFACE)
        head.pack(fill="x", padx=20, pady=(12, 0))
        D.Label(head, text="专家测试", bg=T.SURFACE, fg=T.TEXT_2,
                 font=(T.UI, T.F_LABEL, "bold")).pack(side="left")
        D.Label(head, text="默认全部关闭 · 回到正常模式恢复人工确认", bg=T.SURFACE,
                 fg=T.TEXT_4, font=(T.UI, T.F_MICRO)).pack(side="left", padx=(10, 0))

        grid = D.Frame(page, bg=T.SURFACE)
        grid.pack(fill="both", expand=True, padx=20, pady=(10, 14))
        grid.columnconfigure(0, weight=1)
        grid.columnconfigure(1, weight=1)
        grid.rowconfigure(0, weight=0)

        left_panel = RoundedPanel(grid, fill=T.PANEL, radius=16)
        left_panel.configure(height=268)
        left_panel.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        left = left_panel.content
        D.Label(left, text="确认行为", bg=T.PANEL, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16, pady=(12, 0))
        row = D.Frame(left, bg=T.PANEL)
        row.pack(fill="x", padx=16, pady=(8, 0))
        D.Label(row, text="自动发送接收确认", bg=T.PANEL, fg=T.TEXT_2,
                 font=(T.UI, T.F_LABEL)).pack(side="left")
        self.auto_switch = Switch(row, False, lambda _v: self._expert_changed(),
                                  bg=T.PANEL, tone=T.VERM)
        self.auto_switch.pack(side="right")
        D.Label(left, text="开启后告警到达即发送 ACK，仅用于测试误操作路径；"
                            "断言力弱于人工确认与回执复核。",
                 bg=T.PANEL, fg=T.TEXT_4, font=(T.UI, T.F_MICRO),
                 justify="left").pack(anchor="w", padx=16, pady=(6, 0))

        D.Label(left, text="模拟设备操作", bg=T.PANEL, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16, pady=(16, 0))
        inject = D.Frame(left, bg=T.PANEL)
        inject.pack(fill="x", padx=16, pady=(8, 14))
        for text, op in (("模拟求援", "sim_alarm"), ("模拟恢复", "sim_recover")):
            FlatButton(inject, text, lambda o=op: self.send({"op": o}), 80, 30, "ghost",
                       font=(T.UI, T.F_MICRO)).pack(side="left", padx=(0, 8))
        D.Label(inject, text="仅模拟设备可用", bg=T.PANEL, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="left")

        right_panel = RoundedPanel(grid, fill=T.PANEL, radius=16)
        right_panel.configure(height=268)
        right_panel.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        right = right_panel.content
        D.Label(right, text="协议与能力", bg=T.PANEL, fg=T.TEXT_3,
                 font=(T.UI, T.F_MICRO)).pack(anchor="w", padx=16, pady=(12, 6))
        self.caps_label = D.Label(right, text="未握手", bg=T.PANEL, fg=T.TEXT_2,
                                   font=(T.MONO, T.F_MONO), justify="left", anchor="w")
        self.caps_label.pack(anchor="w", padx=16)
        D.Label(right, text="v1 兼容　ELEV／ALERT 会改写串口告警，告警期间禁止写楼层\n"
                             "v1.1 扩展　FLOOR 只更新楼层 · STAT 原子快照 · INFO 能力握手\n"
                             "STAT 边界　不含像素域页号、五态控制器与显示器连接",
                 bg=T.PANEL, fg=T.TEXT_4, font=(T.UI, T.F_MICRO),
                 justify="left").pack(anchor="w", padx=16, pady=(10, 14))
        self.expert_scroll.bind_wheel()

    def _expert_row(self, parent, title, hint):
        row = D.Frame(parent, bg=T.PANEL)
        row.pack(fill="x", padx=16, pady=(14, 0))
        D.Label(row, text=title, bg=T.PANEL, fg=T.TEXT_2,
                 font=(T.UI, T.F_LABEL)).pack(side="left")
        switch = Switch(row, False, lambda _v: self._expert_changed(), bg=T.PANEL)
        switch.pack(side="right")
        D.Label(row, text=hint, bg=T.PANEL, fg=T.TEXT_4,
                 font=(T.UI, T.F_MICRO)).pack(side="left", padx=(10, 0))
        return switch

    # ==================================================================
    # 交互
    # ==================================================================
    def _bind_keys(self):
        self.root.bind("<F11>", lambda _e: self.toggle_full())
        self.root.bind("<F8>", lambda _e: self.toggle_presentation())
        self.root.bind("<Escape>", lambda _e: self.root.attributes("-fullscreen", False))
        self.root.bind("<space>", lambda _e: self._space())
        self.root.bind("<Control-e>", lambda _e: self.export_csv())
        self.root.bind("<Control-E>", lambda _e: self.export_csv())
        self.root.bind("<Control-t>", lambda _e: self.cycle_theme())
        self.root.protocol("WM_DELETE_WINDOW", self.close)

    def cycle_theme(self):
        self.set_theme(T.next_key(T.current().key))

    def _space(self):
        if self.root.focus_get() == getattr(self, "raw_entry", None):
            return
        demo = self.snap.get("demo", {})
        if demo.get("running"):
            self.send({"op": "pause"})
        elif demo.get("paused"):
            self.send({"op": "resume"})

    def send(self, command: dict):
        if self.replay:
            return
        self.commands.put(command)

    def toggle_full(self):
        self.root.attributes("-fullscreen", not bool(self.root.attributes("-fullscreen")))

    def toggle_mute(self):
        self.status_mid.set("告警声音由 FPGA 终端控制")

    def refresh_ports(self):
        ports = []
        try:
            from serial.tools import list_ports
            for item in list_ports.comports():
                ports.append(f"{item.device} · {item.description[:26]}")
        except Exception:
            pass
        ports.append("SIM-01 · 内置模拟设备")
        self.port_box["values"] = ports
        if not self.port.get():
            self.port.set(next((p for p in ports if p.startswith("COM18")), ports[0]))

    def _port_name(self) -> str:
        return self.port.get().split(" ")[0].strip()

    def toggle_connect(self):
        if self.snap.get("link", {}).get("state") in ("online", "fault", "connecting"):
            self.send({"op": "disconnect"})
        else:
            self.send({"op": "connect", "port": self._port_name()})

    def pick_floor(self, floor: int):
        self.manual_floor = floor
        for value, button in self.floor_buttons.items():
            button.set_kind("primary" if value == floor else "ghost")

    def pick_dir(self, value: str):
        self.manual_dir.set(value)
        for key, button in self._manual_dir_buttons.items():
            button.set_kind("primary" if key == value else "ghost")

    def pick_door(self, value: str):
        self.manual_door.set(value)
        for key, button in self._manual_door_buttons.items():
            button.set_kind("primary" if key == value else "ghost")

    def send_manual(self):
        self.send({"op": "manual", "floor": self.manual_floor,
                   "direction": self.manual_dir.get(), "door": self.manual_door.get()})

    def _route_changed(self):
        self._render_demo(self.snap.get("demo", {}), self.snap.get("link", {}),
                          self.snap.get("device", {}), False)

    def start_demo(self):
        try:
            start, end = int(self.demo_start_floor.get()), int(self.demo_end_floor.get())
        except ValueError:
            self.demo_note.set("请选择 1～5 层的起止楼层")
            return
        if start == end or not 1 <= start <= 5 or not 1 <= end <= 5:
            self.demo_note.set("请选择不同的起点与终点（1～5 层）")
            return
        self.send({"op": "start", "start_floor": start, "end_floor": end,
                   "mode": "single" if self.demo_mode.get() == "单程" else "roundtrip"})

    def send_raw(self, event=None):
        if self.replay or self._raw_pending or self._subtitle_pending or not self.btn_raw_send._enabled:
            return "break"
        try:
            text = P.cmd_raw(self.raw_command.get())[:-2].decode("ascii")
        except P.ProtocolError as error:
            self.raw_send_note.set(str(error))
            self.status_mid.set(str(error))
            return "break"
        self._raw_pending = True
        self.btn_raw_send.set_enabled(False)
        self.raw_send_note.set("已提交串口线程，等待调度结果")
        self.status_mid.set("已提交 · 自动追加 CRLF")
        self.send({"op": "raw_send", "text": text})
        return "break"

    def send_subtitle(self, action):
        if self.replay or self._raw_pending or self._subtitle_pending or not self.subtitle_buttons[0]._enabled:
            return "break"
        try:
            if action == "text":
                text = P.cmd_subtitle(self.subtitle_text.get())[:-2].decode("ascii")
            else:
                text = {"on": "SUB=ON", "off": "SUB=OFF", "cn": "SUB=CN"}[action]
        except P.ProtocolError as error:
            self.subtitle_note.set(str(error))
            return "break"
        self._subtitle_pending = True
        self.subtitle_note.set("已提交调度，等待发送；设备是否接受以串口回执为准。")
        self._render_raw_controls()
        self.send({"op": "raw_send", "text": text})
        return "break"

    def _raw_previous(self, event=None):
        if self.raw_history:
            self.raw_command.set(self.raw_history[-1])
            self.raw_entry.icursor("end")
        return "break"

    def send_ack(self):
        self.send({"op": "ack"})

    def _expert_changed(self):
        self.send({"op": "settings", "auto_ack": self.auto_switch.get(), "ack_delay": 0.0})

    def _timeline_clear(self):
        self.tree.delete(*self.tree.get_children())
        self.entries.clear()
        self.rows = 0
        self.count_text.set("0 条")
        if hasattr(self, "empty_hint"):
            self.empty_hint.place(relx=0.5, rely=0.58, anchor="center")

    def export_csv(self):
        destination = filedialog.asksaveasfilename(defaultextension=".csv",
                                                   filetypes=[("CSV", "*.csv")])
        if destination:
            try:
                count = J.export_csv(self.log_path, Path(destination))
                self.status_mid.set(f"已导出 {count} 行 → {Path(destination).name}")
            except Exception as error:
                self.status_mid.set(f"导出失败：{error}")

    def load_replay(self):
        if self.snap.get("link", {}).get("state", "offline") != "offline":
            self.status_mid.set("请先断开设备，再查看历史记录")
            return
        path = filedialog.askopenfilename(filetypes=[("JSONL", "*.jsonl"), ("全部", "*.*")])
        if not path:
            return
        entries = J.read_entries(Path(path), limit=4000)
        self.tree.delete(*self.tree.get_children())
        self.replay_list.delete("1.0", "end")
        count = 0
        for item in entries:
            self.replay_list.insert(
                "end", f"{item.get('ts', '')}  {item.get('dir', ''):>2}  "
                       f"{item.get('raw', '')}\n", "rx")
            if item.get("kind") in ("rescue", "status", "elev", "stat", "err"):
                self.tree.insert("", "end", values=(
                    item.get("ts", "")[11:19], item.get("kind", ""),
                    item.get("event_id", ""), item.get("floor", ""),
                    item.get("state", ""), item.get("raw", "")[:96]), tags=("replay",))
                count += 1
        self.replay = True
        self._replay_content = self.replay_list.get("1.0", "end-1c")
        self._replay_name = f"历史记录 · {Path(path).name} · {len(entries)} 条"
        if hasattr(self, "empty_hint"):
            self.empty_hint.place_forget()
        self.replay_label.configure(text=self._replay_name)
        self.replay_banner.configure(
            text="离线历史查看：设备已断开；本页只展示日志，不代表设备当前状态。", fg=T.AMBER)
        self.count_text.set(f"{count} 条")
        self._set_controls(False)

    def exit_replay(self):
        self.replay = False
        self._replay_content = ""
        self._replay_name = ""
        self.replay_label.configure(text="未载入")
        self.replay_banner.configure(
            text="请先断开设备，再载入历史记录。历史数据不代表设备当前状态。", fg=T.TEXT_4)
        self.replay_list.delete("1.0", "end")
        self._set_controls(True)

    def _set_controls(self, enabled: bool):
        for button in (self.btn_start, self.btn_pause, self.btn_resume, self.btn_stop,
                       self.btn_manual, self.btn_connect, self.btn_ack):
            button.set_enabled(enabled)
        self._render_raw_controls()
        for box in self.route_boxes:
            box.configure(state="disabled" if self.replay else "readonly")

    def close(self):
        self.core.stop_event.set()
        self.root.after(120, self.root.destroy)

    # ==================================================================
    # 事件泵
    # ==================================================================
    def _drain(self):
        batch = 0
        try:
            while batch < 260:
                event = self.events.get_nowait()
                kind = event.get("kind")
                if kind == "snapshot":
                    self.snap = event
                elif kind == "entry":
                    self._append_entry(event)
                elif kind == "raw":
                    self._append_raw(event)
                elif kind == "raw_send_result":
                    if self._subtitle_pending:
                        self._subtitle_pending = False
                        self.subtitle_note.set(event.get("note", "") + "；设备回执请查看原始串口。")
                    self._raw_pending = False
                    self.raw_send_note.set(event.get("note", ""))
                    self.status_mid.set(event.get("note", ""))
                    if event.get("accepted"):
                        text = event.get("text", "")
                        if not self.raw_history or self.raw_history[-1] != text:
                            self.raw_history.append(text)
                            self.raw_history = self.raw_history[-20:]
                    self._render_raw_controls()
                elif kind == "subtitle_feedback":
                    self.subtitle_note.set(event.get("note", ""))
                elif kind == "notice":
                    self.status_mid.set(event.get("text", ""))
                    if event.get("tone") in ("warn", "error") and hasattr(self, "btn_manual"):
                        if self.btn_manual.winfo_exists():
                            self.btn_manual.flash()
                elif kind == "link":
                    self._on_link(event)
                elif kind == "clearlog":
                    self.raw.delete("1.0", "end")
                batch += 1
        except queue.Empty:
            pass
        self.root.after(40, self._drain)

    def _hover_row(self, event):
        self._set_hover_row(self.tree.identify_row(event.y))

    def _set_hover_row(self, iid: str):
        if getattr(self, "_hover_iid", "") == iid:
            return
        previous = getattr(self, "_hover_iid", "")
        if previous:
            try:
                tags = [t for t in self.tree.item(previous, "tags") if t != "hover"]
                self.tree.item(previous, tags=tags)
            except tk.TclError:
                pass
        self._hover_iid = iid
        if iid:
            try:
                tags = list(self.tree.item(iid, "tags")) + ["hover"]
                self.tree.item(iid, tags=tags)
            except tk.TclError:
                pass

    def _append_entry(self, event, store=True):
        if store:
            self.entries.append(event)
            if len(self.entries) > 400:
                del self.entries[: len(self.entries) - 400]
        if self.replay:
            return
        self._insert_entry(event)
        children = self.tree.get_children()
        if len(children) > 400:
            self.tree.delete(*children[380:])

    def _insert_entry(self, event):
        self.tree.insert("", 0, values=(
            event.get("clock", ""), event.get("tag", ""), event.get("id", ""),
            event.get("floor", ""), event.get("status", ""), event.get("text", "")),
            tags=(event.get("tone", "mute"),))
        self.rows += 1
        self.count_text.set(f"{self.rows} 条")
        if hasattr(self, "empty_hint"):
            self.empty_hint.place_forget()

    def _append_raw(self, event, store=True):
        if store:
            self.raw_lines.append(event)
        self._insert_raw(event)

    def _insert_raw(self, event):
        arrow = "»" if event.get("dir") == "tx" else "«"
        tag = "tx" if event.get("dir") == "tx" else (
            "bad" if event.get("tag") == "invalid" else "rx")
        self.raw.insert("end", f"{event.get('clock', '')}  {arrow} ", ("clock",))
        self.raw.insert("end", f"{event.get('text', '')}\n", (tag,))
        if int(self.raw.index("end-1c").split(".")[0]) > 600:
            self.raw.delete("1.0", "60.0")
        if self.auto_scroll.get():
            self.raw.see("end")

    def _restore_buffers(self):
        self.rows = 0
        for event in self.entries:
            self._insert_entry(event)
        for event in self.raw_lines:
            self._insert_raw(event)
        if not self.entries and hasattr(self, "empty_hint"):
            self.empty_hint.place(relx=0.5, rely=0.58, anchor="center")

    def _on_link(self, event):
        state = event.get("state")
        if state == "offline":
            self._raw_pending = False
            self._subtitle_pending = False
            self.subtitle_note.set("连接已断开；字幕状态未知。")
            self.btn_raw_send.set_enabled(False)
            self.raw_entry.configure(state="disabled")
        if state == "online":
            self.status_mid.set(f"会话已建立 · {event.get('port', '')}")
        elif state == "offline":
            self.status_mid.set(
                f"连接失败：{event['error']}" if event.get("error")
                else "已断开 · 选择端口后重新连接")

    # ==================================================================
    # 周期刷新
    # ==================================================================
    def _tick(self):
        if self.snap:
            try:
                self._render()
            except Exception as error:
                self.status_mid.set(f"界面刷新异常：{error}")
        self.root.after(140, self._tick)

    def _render(self):
        snap = self.snap
        link = snap.get("link", {})
        dev = snap.get("device", {})
        demo = snap.get("demo", {})
        alarm = snap.get("alarm")
        state = link.get("state", "offline")
        online = state in ("online", "fault")

        self._render_topbar(link, dev, state, online)
        floor, known = self._render_readback(dev, demo, snap)
        self._render_shaft(floor, known, dev, demo, alarm)
        self._render_demo(demo, link, dev, online)
        self._render_band(alarm, state, snap.get("stats", {}), dev)
        self._render_status(dev, snap)
        self._render_presentation(snap)
        self._render_raw_controls()
        self.auto_switch.set(bool(snap.get("auto_ack")))
        if self.replay:
            self._set_controls(False)
        if self.tabbar.active == 2:
            self._render_boot()

    def _render_topbar(self, link, dev, state, online):
        simulated = bool(link.get("sim")) and online
        self.environment_tag.configure(
            text="SIM · 模拟演示" if simulated else ("UART · 实机连接" if online else "离线待连接"),
            bg=T.AMBER_BG if simulated else T.PANEL_HI,
            fg=T.AMBER if simulated else T.TEXT_2)
        self.link_text.set({"online": "已连接", "fault": "通信异常",
                            "connecting": "连接中", "offline": "未连接"}.get(state, "未连接"))
        if online:
            age = link.get("age")
            age_text = "等待回读" if age is None else f"{age:.1f}s 前"
            self.link_sub.set(f"{link.get('port') or '—'}"
                              f"{' · 模拟设备' if link.get('sim') else ''} · "
                              f"有效回包 {age_text}")
        else:
            self.link_sub.set("选择串口后连接 · 115200 8N1 · 人工确认")
        tone = T.JADE if state == "online" else (T.VERM if state == "fault" else T.TEXT_4)
        self.link_dot.itemconfigure(1, fill=tone)
        age = link.get("age")
        if state != "online":
            level = 0
        elif age is None:
            level = 2
        else:
            level = 4 if age < 0.9 else (3 if age < 2.4 else 2)
        self.signal.set_level(level, T.VERM if state == "fault" else None)
        self.btn_connect.set_text("断开连接" if online or state == "connecting" else "连接设备")
        self.port_box.configure(state="disabled" if online else "readonly")
        self.btn_connect.set_kind("ghost" if online else "primary")

    def _render_readback(self, dev, demo, snap):
        floor = dev.get("floor", "--")
        known = bool(dev.get("known"))
        received = bool(dev.get("status_received", known))
        link_state = snap.get("link", {}).get("state")
        age = dev.get("floor_age")
        current = received and link_state == "online" and age is not None and age <= 6.0
        self.floor_label.configure(text=floor if known else "--",
                                   fg=T.TEXT if current else (T.AMBER if known else T.TEXT_4))
        self.floor_src.configure(
            text={"stat": "STAT", "elev": "ELEV?"}.get(dev.get("floor_src"), "—")
            if received else "未回读")
        target = demo.get("target")
        if target and (not known or f"{target[0]:02d}" != floor):
            self.target_line.configure(
                text=f"目标 {target[0]:02d} {P.DIRECTION_GLYPH.get(target[1], '')} · 待回读",
                fg=T.AMBER)
        elif target:
            self.target_line.configure(text="目标 — · 与回读一致", fg=T.TEXT_4)
        elif received and floor == "00":
            self.target_line.configure(text="F00 · 待初始化", fg=T.AMBER)
        else:
            self.target_line.configure(text="未下发目标", fg=T.TEXT_4)
        self.readback_tag.configure(text=("已解析 · 待初始化" if current and not known else "已回读")
                                    if current else ("历史值 · 待同步" if received else "等待回读"),
                                    fg=(T.JADE if known else T.AMBER) if current else
                                    (T.AMBER if received else T.TEXT_4))

        def kv(key, text, color=T.TEXT_2):
            self.kv[key].configure(text=text, fg=color)

        direction = dev.get("direction", "S")
        kv("direction", (f"{P.DIRECTION_GLYPH.get(direction, '')} "
                          f"{P.DIRECTION_TEXT.get(direction, '')}".strip())
           if dev.get("direction_valid", received) else "未回读",
           T.TEXT if current else T.TEXT_4)
        door = dev.get("door")
        kv("door", ("未知" if door == "M" else P.DOOR_TEXT.get(door, "未知"))
           if dev.get("door_valid", received) else "未回读", T.TEXT if current else T.TEXT_4)
        comm = dev.get("comm", "IDLE")
        kv("comm", P.COMM_TEXT.get(comm, comm) if dev.get("comm_valid", dev.get("alert_src") != "none") else "未回读",
           T.TEXT_4 if not current else
           {"ACKED": T.JADE, "TIMEOUT": T.AMBER, "WAIT": T.TEXT}.get(comm, T.TEXT_2))
        error = dev.get("error", "--")
        kv("error", ("未提供" if received else "未回读") if error == "--" else ("无" if error == "00" else f"代码 {error}"),
           T.AMBER if error not in ("--", "00") else T.TEXT_3)
        kv("alert", "有效告警" if dev.get("alert") else
           ("未同步" if dev.get("alert_src", "none") == "none" else "无有效告警"),
           T.VERM if dev.get("alert") else T.TEXT_2)
        kv("mode", demo.get("text", "未运行"),
           T.JADE if demo.get("running") else (T.AMBER if demo.get("paused") else T.TEXT_2))
        age = dev.get("floor_age")
        if age is None or age == float("inf"):
            kv("fresh", "无数据", T.TEXT_4)
        else:
            kv("fresh", f"{age:.1f}s",
               T.JADE if age <= 2.4 else (T.AMBER if age <= 6 else T.VERM))
        kv("source", {"stat": "系统域", "elev": "系统域", "rescue": "求援快照"}.get(
            dev.get("alert_src"), "—"))

        now = snap.get("ts", 0.0)
        self.trace.push(now, P.floor_index(floor) if current and known else None)
        self.trace.redraw(now)
        return floor, known

    def _render_shaft(self, floor, known, dev, demo, alarm):
        alert_floor = None
        if alarm and not alarm.get("resolved"):
            try:
                alert_floor = int(alarm["floor"])
            except (TypeError, ValueError):
                alert_floor = None
        self.shaft.set_state(P.floor_index(floor) if known else None,
                             target=demo.get("target"), direction=dev.get("direction", "S"),
                             door=dev.get("door", "C"), alert_index=alert_floor,
                             known=known, stale=self.snap.get("link", {}).get("state") != "online"
                             or dev.get("floor_age", float("inf")) > 6.0)
        self.shaft_note.configure(
            text="告警楼层已标红" if alert_floor else
            ("轿厢跟随回读" if known and P.floor_index(floor) is not None else
             ("回读楼层超出井道范围" if known else "")))

    def _render_demo(self, demo, link, dev, online):
        self.demo_state_label.configure(
            text=demo.get("text", "未运行"),
            fg=T.JADE if demo.get("running") else (T.AMBER if demo.get("paused") else T.TEXT_4))
        running, paused = demo.get("running"), demo.get("paused")
        ready = self._control_ready(self.snap)
        route_valid = (self.demo_start_floor.get() in ("1", "2", "3", "4", "5") and
                       self.demo_end_floor.get() in ("1", "2", "3", "4", "5") and
                       self.demo_start_floor.get() != self.demo_end_floor.get())
        self.btn_start.set_enabled(ready and not running and not paused and route_valid)
        for box in self.route_boxes:
            box.configure(state="disabled" if running or paused or self.replay else "readonly")
        self.btn_start.set_text("初始化演示" if ready and not dev.get("known") else "开始演示")
        self.btn_pause.set_enabled(ready and running)
        room = P.floor_index(dev.get("floor", ""))
        low, high = sorted((demo.get("start_floor", 1), demo.get("end_floor", 5)))
        self.btn_resume.set_enabled(ready and paused and room is not None and low <= room <= high)
        self.btn_stop.set_enabled(bool(running or paused) and not self.replay)
        self.btn_start.set_kind("primary" if not running and not paused else "ghost")
        self.btn_pause.set_kind("primary" if running else "ghost")
        self.btn_resume.set_kind("primary" if paused else "ghost")
        self.btn_manual.set_enabled(ready and not running)
        for button in (*self.floor_buttons.values(), *self._manual_dir_buttons.values(),
                       *self._manual_door_buttons.values()):
            button.set_enabled(ready and not running)
        if demo.get("running"):
            self.demo_note.set(f"第 {demo.get('step', 0)} 步 · 下一步 "
                               f"{demo.get('next_in', 0):.1f}s · "
                               f"{'事务在途' if link.get('busy') else '队列空闲'}")
            period = max(0.1, demo.get("period", 2.0))
            self.demo_bar.set(1 - min(1.0, demo.get("next_in", 0) / period), T.JADE)
        else:
            start, end = self.demo_start_floor.get(), self.demo_end_floor.get()
            arrow = "↔" if self.demo_mode.get() == "往返" else "→"
            direction = "上行" if start < end else "下行"
            self.demo_note.set("请选择不同的起点与终点" if not route_valid else (
                f"已到达 {demo.get('end_floor')} 层 · 单程完成" if demo.get("completed") else (
                f"{demo.get('route', start + arrow + end)} · 已暂停，继续或停止" if paused else
                f"{start}{arrow}{end} · {direction}出发 · 每 2 秒一层")))
            self.demo_bar.set(0, T.LINE)

    def _render_raw_controls(self):
        connected = self.snap.get("link", {}).get("state") in ("online", "fault")
        enabled = connected and not self.replay
        self.btn_raw_send.set_enabled(enabled and not self._raw_pending and not self._subtitle_pending)
        self.raw_entry.configure(state="normal" if enabled else "disabled")
        if hasattr(self, "subtitle_buttons"):
            for button in self.subtitle_buttons:
                button.set_enabled(enabled and not self._raw_pending and not self._subtitle_pending)
            self.subtitle_entry.configure(state="normal" if enabled else "disabled")

    def _render_status(self, dev, snap):
        self.status_left.set(f"RX {dev.get('rx_lines', 0)} · TX {dev.get('tx_lines', 0)} · "
                             f"无效 {dev.get('invalid_lines', 0)}")
        journal = snap.get("journal", {})
        self.status_right.set("日志写入失败" if journal.get("failed") else
                              f"日志 {journal.get('count', 0)} 条")
        self.journal_label.configure(fg=T.VERM if journal.get("failed") else T.TEXT_3)
        caps = snap.get("caps", 0)
        names = [name for bit, name in ((1, "FLOOR"), (2, "STAT"), (4, "INFO"), (8, "COMM"))
                 if caps & bit]
        info = dev.get("info", {})
        self.caps_label.configure(
            text=f"INFO  P=1.{(info.get('proto', 0) & 0x0F) or 0}  "
                 f"FW={info.get('firmware', '----')}  HW={info.get('hardware', '----')}\n"
                 f"CAP   {' '.join(names) if names else '未声明 · v1 兼容模式'}")

    @staticmethod
    def _control_ready(snap):
        link, dev = snap.get("link", {}), snap.get("device", {})
        alarm = snap.get("alarm") or {}
        age = dev.get("floor_age")
        alert_age = dev.get("alert_age", age)
        return bool(link.get("state") == "online" and dev.get("status_received", dev.get("known"))
                    and age is not None and age <= 6.0
                    and alert_age is not None and alert_age <= 6.0
                    and dev.get("alert_src", "none") != "none"
                    and not dev.get("alert")
                    and not (alarm and not alarm.get("resolved")))

    def _render_presentation(self, snap):
        link, dev = snap.get("link", {}), snap.get("device", {})
        alarm = snap.get("alarm") or {}
        simulated = bool(link.get("sim")) and link.get("state") == "online"
        self.btn_sim_alarm.set_enabled(simulated and not self.replay and not self._is_alarm())
        self.btn_sim_recover.set_enabled(simulated and not self.replay and self._is_alarm())
        self.present_scope.configure(
            text="模拟演示 · 不计为实板验收" if simulated else
            ("设备已连接 · 串口状态驱动" if link.get("state") == "online" else "设备未就绪 · 控制已禁用"),
            fg=T.AMBER if simulated else T.TEXT_3)
        if simulated and not self.present_sim.winfo_manager():
            self.present_sim.pack(side="right", padx=(12, 0))
        elif not simulated:
            self.present_sim.pack_forget()
        stats = snap.get("stats", {})
        text = f"会话求援 {stats.get('total', 0)} 次    设备确认 {stats.get('acked', 0)} 次"
        if alarm and not alarm.get("resolved"):
            text = f"事件 {alarm.get('id', '—')}  ·  {self._ack_text(alarm)}  ·  告警仍有效"
        elif not self._control_ready(snap):
            text += "    等待设备状态同步"
        else:
            text += "    日常运行"
        self.present_summary.configure(text=text, fg=T.AMBER if self._is_alarm() else T.TEXT_2)
        if self.entries:
            entry = self.entries[-1]
            self.present_event.configure(text=f"最近事件  {entry.get('clock', '')}  ·  {entry.get('text', '')}")

    def _render_band(self, alarm, link_state, stats=None, dev=None):
        dev = dev or {}
        active = bool(alarm and not alarm.get("resolved"))
        steps = (("01  设备告警", active),
                 ("02  接收确认", active and alarm.get("ack") in ("sent", "acked")),
                 ("03  设备回执", active and alarm.get("acked")))
        for label, (text, complete) in zip(self.flow_labels, steps):
            label.configure(text=text, fg=T.JADE if complete else T.TEXT_4)
        if active:
            acked = alarm.get("acked")
            color = T.BAND_ACK_BG if acked else T.VERM_BG
            if color != self._band_color:
                self._paint_band(color)
            self.band_accent.configure(bg=T.AMBER if acked else T.VERM)
            self.band_title_label.configure(fg=T.AMBER if acked else T.VERM)
            self.band_title.set("请求已确认 · 告警仍有效" if acked else "紧急求援 · 等待响应")
            self.band_id.set(alarm.get("id", ""))
            self.band_id_label.configure(fg=T.AMBER if acked else T.VERM)
            duration = alarm.get("duration", 0)
            self.band_meta.set(
                f"楼层 {alarm.get('floor', '--')} · "
                f"{P.DIRECTION_TEXT.get(alarm.get('direction'), '—')} · "
                f"{P.DOOR_TEXT.get(alarm.get('door'), '—')} · "
                f"来源 {P.SOURCE_TEXT.get(alarm.get('source'), '—')} · "
                f"故障 {alarm.get('error', '--')} · "
                f"持续 {int(duration // 60):02d}:{int(duration % 60):02d} · "
                f"接收 {alarm.get('count', 1)} 次")
            self.band_meta_label.configure(fg=T.TEXT_2)
            self.band_state.set(self._ack_text(alarm))
            self.band_state_label.configure(fg=T.JADE if acked else T.AMBER)
            ack = alarm.get("ack")
            self.btn_ack.set_enabled(not self.replay and link_state == "online" and not acked
                                     and not alarm.get("conflict")
                                     and ack not in ("sending", "blocked"))
            label = {"sending": "发送中…", "sent": "已发出",
                     "timeout": "重发接收确认"}.get(ack, "收到响应 · ACK")
            self.btn_ack.set_text("已确认" if acked else label)
            self.btn_ack.set_kind("ghost" if acked else "danger")
            self.btn_details.set_enabled(True)
            if not self.band_actions.winfo_ismapped():
                self.band_actions.pack(anchor="e")
            self._band_active = True
        elif dev.get("alert"):
            if self._band_color != T.VERM_BG:
                self._paint_band(T.VERM_BG)
            self.band_accent.configure(bg=T.VERM)
            self.band_title_label.configure(fg=T.VERM)
            self.band_title.set("设备告警 · 等待事件同步")
            self.band_id.set("")
            self.band_meta.set("设备回读告警有效，尚未收到完整求援事件；普通控制已禁用")
            self.band_meta_label.configure(fg=T.TEXT_2)
            self.band_state.set("事件未同步 · 暂不可确认")
            self.band_state_label.configure(fg=T.AMBER)
            self.btn_ack.set_enabled(False)
            self.btn_ack.set_text("等待事件编号")
            self.band_actions.pack(anchor="e")
            self._band_active = True
        elif link_state not in ("online", "connecting") and dev and dev.get("status_received", dev.get("known")):
            if self._band_color != T.AMBER_BG:
                self._paint_band(T.AMBER_BG)
            self.band_accent.configure(bg=T.AMBER)
            self.band_title_label.configure(fg=T.AMBER)
            self.band_title.set("链路中断")
            self.band_id.set("")
            self.band_meta_label.configure(fg=T.TEXT_2)
            age = dev.get("floor_age")
            if age in (None, float("inf")):
                age_text = "未知"
            elif age < 90:
                age_text = f"{age:.1f}s 前"
            else:
                age_text = f"{age / 60:.0f} 分钟前"
            self.band_meta.set(
                f"最后回读 F{dev.get('floor', '--')} · {age_text} · "
                f"控制已禁用，等待重新连接后同步")
            self.band_state.set("显示的是旧值")
            self.band_state_label.configure(fg=T.AMBER)
            if self.band_actions.winfo_ismapped():
                self.band_actions.pack_forget()
            self._band_active = False
        else:
            if self._band_color != T.SURFACE:
                self._paint_band(T.SURFACE)
            self.band_accent.configure(bg=T.LINE)
            self.band_title_label.configure(fg=T.TEXT_2)
            synchronized = link_state == "online" and dev.get("alert_src", "none") != "none"
            self.band_title.set("运行监视 · 无有效告警" if synchronized else "等待连接与状态同步")
            self.band_id.set("")
            self.band_meta_label.configure(fg=T.TEXT_4)
            if alarm and alarm.get("resolved"):
                self.band_meta.set(
                    f"最近事件 {alarm.get('id', '')} 已解除 · "
                    f"原因 {alarm.get('reason', '') or '设备恢复'} · 演示保持暂停，等待人工继续")
                self.band_state.set("已解除")
                self.band_state_label.configure(fg=T.TEXT_3)
            else:
                self.band_meta.set("告警到达后置顶提示；接收确认不等于告警解除或救援到场" if synchronized else
                                   "连接真实串口或 SIM 模拟设备，收到有效状态后开放普通控制")
                self.band_meta_label.configure(fg=T.TEXT_3)
                stats = stats or {}
                self.band_state.set(
                    f"本次会话 · 求援 {stats.get('total', 0)} 次 · "
                    f"设备确认 {stats.get('acked', 0)} 次")
                self.band_state_label.configure(fg=T.TEXT_4)
            if self.band_actions.winfo_ismapped():
                self.band_actions.pack_forget()
            self._band_active = False

    @staticmethod
    def _ack_text(alarm) -> str:
        return {
            "none": "等待接收确认",
            "sending": "确认发送中",
            "sent": "确认已发出，待设备回执",
            "acked": "设备已接受接收确认",
            "timeout": "设备确认超时，可重发",
            "blocked": "记录失败，禁止确认",
        }.get(alarm.get("ack"), "")

    def _paint_band(self, color: str):
        self._band_color = color
        for widget in self._band_parts:
            try:
                widget.configure(bg=color)
            except tk.TclError:
                pass
        self.btn_ack.configure_bg(color)
        self.btn_details.configure_bg(color)

    def _pulse_tick(self):
        """低频呼吸只作用在左侧 4px 竖条上，不改变布局与文字。"""
        alarm = self.snap.get("alarm") or {}
        if alarm and not alarm.get("resolved") and not alarm.get("acked"):
            self._pulse = 1 - self._pulse
            self.band_accent.configure(bg=T.VERM if self._pulse else T.RING_MUTED)
        self.root.after(820, self._pulse_tick)

    def _is_alarm(self) -> bool:
        alarm = self.snap.get("alarm")
        return bool(alarm and not alarm.get("resolved"))

    def _render_boot(self):
        canvas = self.boot_canvas
        canvas.delete("all")
        boot = self.snap.get("device", {}).get("boot")
        width = canvas.logical_width() if canvas.winfo_width() > 1 else 900
        if not boot:
            canvas.create_text(4, 24, text="尚未查询启动计时 · 点击右上「查询 BOOT?」",
                               anchor="w", fill=T.TEXT_4, font=(T.UI, T.F_LABEL))
            return
        valid = boot.get("valid", 0)
        span = max(1, boot.get("pic5_ms", 1))
        self.boot_note.set(f"BOOT? 原子快照 · 有效位 {valid:02X} · 起点为复位释放")
        for index, (key, label) in enumerate(BOOT_NODES):
            y = 18 + index * 36
            happened = bool(valid & (1 << index))
            value = boot.get(key, 0)
            canvas.create_text(2, y, text=f"{index + 1}", anchor="w", fill=T.TEXT_4,
                               font=(T.MONO, -9))
            canvas.create_text(20, y, text=label, anchor="w",
                               fill=T.TEXT if happened else T.TEXT_3,
                               font=(T.UI, T.F_LABEL))
            canvas.create_rectangle(120, y - 6, width - 90, y + 2, fill=T.LINE_SOFT,
                                    outline="")
            if happened:
                ratio = min(1.0, value / span)
                canvas.create_rectangle(120, y - 6, 120 + max(3, (width - 210) * ratio),
                                        y + 2,
                                        fill=T.AMBER if value >= 0xFFFF else T.JADE,
                                        outline="")
                text = "饱和 FFFF" if value >= 0xFFFF else f"{value} ms"
            else:
                text = "未发生"
            canvas.create_text(width - 2, y, text=text, anchor="e",
                               fill=T.TEXT_2 if happened else T.TEXT_4,
                               font=(T.MONO, -10))


def launch(log_path: Path):
    root = D.create_root()
    Console(root, log_path)
    root.mainloop()
