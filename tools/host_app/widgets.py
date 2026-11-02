"""自绘控件。所有像素坐标按 96dpi 设计，颜色与字体统一取自 theme。"""
from __future__ import annotations

import tkinter as tk

from . import theme as T
from . import display as D


def hairline(parent, color=None):
    return D.Frame(parent, height=1, bg=color or T.LINE, bd=0, highlightthickness=0)


def vline(parent, color=None, width=1):
    return D.Frame(parent, width=width, bg=color or T.LINE, bd=0, highlightthickness=0)


class FlatButton(D.Canvas):
    """圆角按钮；按当前 DPI 直接绘制，支持鼠标和键盘操作。"""

    def __init__(self, master, text, command=None, width=96, height=32,
                 kind="ghost", font=None, glyph="", pad=12, bg=None):
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0, takefocus=1)
        self._text = text
        self._command = command
        self._kind = kind
        self._cw, self._ch = width, height
        self._font = font or (T.UI, T.F_LABEL)
        self._glyph = glyph
        self._pad = pad
        self._enabled = True
        self._hover = False
        self._press = False
        self._focused = False
        self._flash_color = None
        self.bind("<Enter>", self._enter)
        self.bind("<Leave>", self._leave)
        self.bind("<Button-1>", self._down)
        self.bind("<ButtonRelease-1>", self._up)
        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<FocusIn>", lambda _e: self._set_focus(True))
        self.bind("<FocusOut>", lambda _e: self._set_focus(False))
        self.bind("<Return>", self._keyboard_activate)
        self.bind("<space>", self._keyboard_activate)
        self._redraw()

    def _keyboard_activate(self, _event):
        if self._enabled and self._command:
            self._command()
        return "break"

    def _set_focus(self, value: bool):
        if self._focused != value:
            self._focused = value
            self._redraw()

    def flash(self, color=None):
        """操作被忽略时的一次性描边提示。"""
        self._flash_color = color or T.AMBER
        self._redraw()
        self.after(320, self._clear_flash)

    def _clear_flash(self):
        self._flash_color = None
        try:
            self._redraw()
        except tk.TclError:
            pass

    # -- 外部接口 ---------------------------------------------------------
    def set_enabled(self, value: bool):
        if self._enabled != value:
            self._enabled = value
            self._redraw()

    def set_text(self, text: str):
        if self._text != text:
            self._text = text
            self._redraw()

    def set_kind(self, kind: str):
        if self._kind != kind:
            self._kind = kind
            self._redraw()

    def configure_bg(self, color: str):
        self.configure(bg=color)
        self._redraw()

    # -- 绘制 -------------------------------------------------------------
    def _colors(self):
        tone = T.button_tone(self._kind)
        if not self._enabled:
            edge = T.LINE_SOFT if tone["border"] else None
            return T.PANEL_HI, T.TEXT_4, edge
        fill, fg, border = tone["fill"], tone["fg"], tone["border"]
        if self._hover:
            fill = tone["hover"] or fill
            border = tone["hover_border"] or border
            if tone.get("hover_fg"):
                fg = tone["hover_fg"]
        if self._press and fill:
            fill = self._mix(fill, "#000000", 0.82)
        return fill, fg, border

    @staticmethod
    def _mix(color: str, other: str, ratio: float) -> str:
        a = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
        b = [int(other[i:i + 2], 16) for i in (1, 3, 5)]
        return "#" + "".join(f"{int(x * ratio + y * (1 - ratio)):02x}" for x, y in zip(a, b))

    def _redraw(self):
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else self._cw
        h = self.logical_height() if self.winfo_height() > 1 else self._ch
        fill, fg, border = self._colors()
        self.rounded_rect(1, 1, w - 1, h - 1, radius=min(11, h / 3),
                          fill=fill or self["bg"], outline=border or "", width=1)
        if self._flash_color:
            self.rounded_rect(2, 2, w - 2, h - 2, radius=10,
                              outline=self._flash_color, fill="", width=2)
        elif self._focused and self._enabled:
            ring = T.TEXT if fill else T.JADE
            self.rounded_rect(3, 3, w - 3, h - 3, radius=9, outline=ring, fill="")
        label = f"{self._glyph}  {self._text}" if self._glyph else self._text
        self.create_text(w / 2, h / 2 + 1, text=label, fill=fg, font=self._font)

    # -- 事件 -------------------------------------------------------------
    def _enter(self, _event):
        self._hover = True
        if self._enabled:
            self.configure(cursor="hand2")
        self._redraw()

    def _leave(self, _event):
        self._hover = self._press = False
        self._redraw()

    def _down(self, _event):
        if not self._enabled:
            return
        self.focus_set()
        self._press = True
        self._redraw()

    def _up(self, _event):
        was = self._press
        self._press = False
        self._redraw()
        if was and self._enabled and self._command:
            self._command()


class RoundedSelect(D.Canvas):
    """只读圆角选择器，字段与弹出列表使用同一字体、配色和逻辑坐标。"""

    def __init__(self, master, textvariable, values, width=72, height=38, font=None, bg=None):
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0, takefocus=1)
        self._variable = textvariable
        self._values = tuple(str(value) for value in values)
        self._font = font or (T.UI, T.F_LABEL)
        self._state = "readonly"
        self._hover = False
        self._focused = False
        self._popup = None
        self._menu = None
        self._active = 0
        self._cw, self._ch = width, height
        self._trace = self._variable.trace_add("write", self._value_changed)
        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<Enter>", lambda _e: self._set_hover(True))
        self.bind("<Leave>", lambda _e: self._set_hover(False))
        self.bind("<FocusIn>", lambda _e: self._set_focus(True))
        self.bind("<FocusOut>", lambda _e: self._set_focus(False))
        self.bind("<Button-1>", self._toggle)
        for key in ("<Return>", "<space>", "<Down>", "<Alt-Down>"):
            self.bind(key, self._toggle)
        self.bind("<Unmap>", lambda _e: self._close())
        self.bind("<Destroy>", self._destroyed)
        self._redraw()

    def cget(self, key):
        if key == "font":
            return D.font(self._font)
        if key == "state":
            return self._state
        if key == "values":
            return self._values
        return super().cget(key)

    def configure(self, cnf=None, **kwargs):
        if isinstance(cnf, str) or (cnf is None and not kwargs):
            return super().configure(cnf)
        options = {**(cnf or {}), **kwargs}
        redraw = False
        if "state" in options:
            state = options.pop("state")
            if state != self._state:
                self._state = state
                if state == "disabled":
                    self._close()
                redraw = True
        if "font" in options:
            self._font = options.pop("font")
            redraw = True
        if "values" in options:
            self._values = tuple(str(value) for value in options.pop("values"))
            self._close()
            redraw = True
        result = super().configure(**options) if options else None
        if redraw:
            self._redraw()
        return result

    config = configure

    def _value_changed(self, *_args):
        self._redraw()

    def _set_hover(self, value):
        self._hover = value
        self._redraw()

    def _set_focus(self, value):
        self._focused = value
        self._redraw()

    def _redraw(self):
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else self._cw
        h = self.logical_height() if self.winfo_height() > 1 else self._ch
        disabled = self._state == "disabled"
        edge = (T.JADE_DIM if self._focused or self._popup else
                T.HOVER_BORDER if self._hover else T.LINE)
        self.rounded_rect(1, 1, w - 1, h - 1, radius=11, fill=T.PANEL_HI,
                          outline=T.LINE_SOFT if disabled else edge, width=1, tags="field")
        self.create_text((w - 18) / 2, h / 2, text=self._variable.get(),
                         fill=T.TEXT_4 if disabled else T.TEXT, font=self._font)
        x, y = w - 15, h / 2
        self.create_line(x - 3, y - 1.5, x, y + 1.5, x + 3, y - 1.5,
                         fill=T.TEXT_4 if disabled else T.TEXT_3, width=1.5,
                         capstyle="round", joinstyle="round")
        self.configure(cursor="" if disabled else "hand2")

    def _toggle(self, _event=None):
        if self._popup is not None:
            self._close(focus=True)
        else:
            self._open()
        return "break"

    def _open(self):
        if self._state == "disabled" or not self._values or self._popup is not None:
            return
        self.focus_set()
        root = self.winfo_toplevel()
        popup = tk.Toplevel(root)
        self._popup = popup
        popup.withdraw()
        popup.overrideredirect(True)
        popup.transient(root)
        key = "#010203"
        popup.configure(bg=key)
        try:
            popup.attributes("-transparentcolor", key)
        except tk.TclError:
            key = T.PANEL
            popup.configure(bg=key)
        width = max(D.px(self._cw), self.winfo_width())
        height = D.px(12 + 36 * len(self._values))
        x = max(0, min(self.winfo_rootx(), root.winfo_screenwidth() - width - D.px(8)))
        y = self.winfo_rooty() + self.winfo_height() + D.px(6)
        if y + height > root.winfo_screenheight() - D.px(8):
            y = max(0, self.winfo_rooty() - height - D.px(6))
        popup.geometry(f"{width}x{height}+{x}+{y}")
        self._menu = D.Canvas(popup, width=D.logical(width), height=D.logical(height),
                              bg=key, highlightthickness=0, bd=0)
        self._menu.pack(fill="both", expand=True)
        self._active = self._values.index(self._variable.get()) if self._variable.get() in self._values else 0
        self._menu.bind("<Motion>", self._menu_motion)
        self._menu.bind("<ButtonRelease-1>", self._menu_click)
        popup.bind("<ButtonPress-1>", self._outside_click)
        popup.bind("<KeyPress>", self._menu_key)
        popup.bind("<FocusOut>", self._lost_focus)
        popup.bind("<Configure>", lambda _e: self._paint_menu())
        popup.deiconify()
        popup.lift()
        self._paint_menu()
        popup.grab_set()
        popup.focus_set()
        self._redraw()

    def _paint_menu(self):
        if self._menu is None:
            return
        canvas = self._menu
        canvas.delete("all")
        w = max(self._cw, D.logical(self.winfo_width()))
        h = 12 + 36 * len(self._values)
        canvas.rounded_rect(1, 1, w - 1, h - 1, radius=11,
                            fill=T.PANEL_HI, outline=T.LINE, width=1, tags="menu_surface")
        selected = self._variable.get()
        for index, value in enumerate(self._values):
            y = 6 + index * 36
            if index == self._active or value == selected:
                canvas.rounded_rect(5, y, w - 5, y + 34, radius=8,
                                    fill=T.JADE_DIM if value == selected else T.PANEL_TOP,
                                    outline="", tags="option_highlight")
            canvas.create_text((w - 12) / 2, y + 17, text=value,
                               fill=T.TEXT, font=self._font, tags="option_text")
            if value == selected:
                canvas.create_line(w - 20, y + 17, w - 17, y + 20, w - 12, y + 14,
                                   fill=T.JADE, width=1.5, capstyle="round")

    def _row_at(self, y):
        logical = D.logical(y) - 6
        index = int(logical // 36)
        return index if logical >= 0 and 0 <= index < len(self._values) else None

    def _menu_motion(self, event):
        index = self._row_at(event.y)
        if index is not None and index != self._active:
            self._active = index
            self._paint_menu()

    def _menu_click(self, event):
        index = self._row_at(event.y)
        if index is not None and 0 <= event.x < self._menu.winfo_width():
            self._choose(index)

    def _outside_click(self, event):
        popup = self._popup
        if popup and not (popup.winfo_rootx() <= event.x_root < popup.winfo_rootx() + popup.winfo_width()
                          and popup.winfo_rooty() <= event.y_root < popup.winfo_rooty() + popup.winfo_height()):
            self._close()
            return "break"

    def _menu_key(self, event):
        if event.keysym in ("Escape", "Tab"):
            self._close(focus=True)
            if event.keysym == "Tab":
                next_widget = self.tk_focusPrev() if event.state & 1 else self.tk_focusNext()
                if next_widget:
                    next_widget.focus_set()
        elif event.keysym in ("Return", "KP_Enter", "space"):
            self._choose(self._active)
        elif event.keysym in ("Up", "Down", "Home", "End"):
            self._active = (0 if event.keysym == "Home" else len(self._values) - 1
                            if event.keysym == "End" else
                            max(0, min(len(self._values) - 1,
                                       self._active + (1 if event.keysym == "Down" else -1))))
            self._paint_menu()
        return "break"

    def _choose(self, index):
        value = self._values[index]
        changed = self._variable.get() != value
        self._variable.set(value)
        self._close(focus=True)
        if changed:
            self.event_generate("<<ComboboxSelected>>", when="tail")

    def _lost_focus(self, _event):
        if self._popup is not None:
            self.after_idle(self._check_focus)

    def _check_focus(self):
        if self._popup is not None:
            focused = self.focus_get()
            if focused is None or focused.winfo_toplevel() != self._popup:
                self._close()

    def _close(self, focus=False):
        popup, self._popup = self._popup, None
        self._menu = None
        if popup is not None:
            try:
                if popup.grab_current() == popup:
                    popup.grab_release()
                popup.destroy()
            except tk.TclError:
                pass
            if self.winfo_exists():
                if focus:
                    self.focus_set()
                self._redraw()

    def _destroyed(self, event):
        if event.widget == self:
            self._close()
            self._variable.trace_remove("write", self._trace)


class RoundedPanel(D.Canvas):
    """A vector rounded surface with an inset frame for native child widgets."""

    def __init__(self, master, fill=None, border=None, radius=18, bg=None, inset=10):
        super().__init__(master, width=1, height=1, bg=bg or master.cget("bg"),
                         highlightthickness=0)
        self.fill = fill or T.PANEL
        self.border = border or T.LINE
        self.radius = radius
        self.inset = inset
        self.content = D.Frame(self, bg=self.fill)
        self.content.place(x=inset, y=inset, relwidth=1, relheight=1,
                           width=-inset * 2, height=-inset * 2)
        self.bind("<Configure>", self._paint)

    def _paint(self, _event=None):
        self.delete("surface")
        w, h = self.logical_width(), self.logical_height()
        if w > 2 and h > 2:
            self.rounded_rect(1, 1, w - 1, h - 1, radius=self.radius,
                              fill=self.fill, outline=self.border, width=1, tags="surface")
            self.tag_lower("surface")


class ScrollablePage(D.Frame):
    """Keep diagnostic content reachable when the native viewport is short."""

    def __init__(self, master, bg=None):
        color = bg or T.SURFACE
        super().__init__(master, bg=color)
        self.canvas = D.Canvas(self, width=1, height=1, bg=color,
                               highlightthickness=0, yscrollincrement=24)
        scrollbar = D.Scrollbar(self, orient="vertical", command=self.canvas.yview,
                                style="S.Vertical.TScrollbar")
        self.canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.canvas.pack(side="left", fill="both", expand=True)
        self.content = D.Frame(self.canvas, bg=color)
        self._window = self.canvas.create_window(0, 0, window=self.content, anchor="nw")
        self.canvas.bind("<Configure>", self._resize)
        self.content.bind("<Configure>", self._extent)

    def _resize(self, event):
        # create_window/itemconfigure use physical pixels in the native Tk canvas.
        self.canvas.itemconfigure(self._window, width=event.width)
        self._extent()

    def _extent(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def bind_wheel(self):
        def attach(widget):
            widget.bind("<MouseWheel>", self._wheel, add="+")
            for child in widget.winfo_children():
                attach(child)
        attach(self)

    def _wheel(self, event):
        if self.canvas.yview() != (0.0, 1.0) and event.delta:
            self.canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")
        return "break"


class TabBar(D.Canvas):
    """圆角分段页签，适配原生 DPI。"""

    def __init__(self, master, items, on_change, bg=None, height=44):
        super().__init__(master, height=height, bg=bg or T.SURFACE, bd=0,
                         highlightthickness=0)
        self._items = list(items)
        self._on_change = on_change
        self._active = 0
        self._hover = -1
        self._boxes: list[tuple[int, int]] = []
        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<Motion>", self._motion)
        self.bind("<Leave>", lambda _e: self._set_hover(-1))
        self.bind("<Button-1>", self._click)

    @property
    def active(self) -> int:
        return self._active

    def select(self, index: int):
        if index != self._active:
            self._active = index
            self._redraw()

    def _redraw(self):
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else 800
        h = self.logical_height() if self.winfo_height() > 1 else T.TABBAR_H
        self.create_line(0, h - 1, w, h - 1, fill=T.LINE_SOFT)
        x = 20
        self._boxes = []
        for index, label in enumerate(self._items):
            text_width = self._measure(label)
            active = index == self._active
            if active or index == self._hover:
                self.rounded_rect(x - 12, 7, x + text_width + 12, h - 7, radius=10,
                                  fill=T.PANEL_HI, outline="")
            color = T.TEXT if active else (T.TEXT_2 if index == self._hover else T.TEXT_3)
            self.create_text(x, h / 2, text=label, anchor="w", fill=color,
                             font=(T.UI, T.F_LABEL, "bold" if active else "normal"))
            self._boxes.append((x - 6, x + text_width + 8))
            x += text_width + 34
        self.create_line(0, 0, w, 0, fill=T.LINE_SOFT)

    def _measure(self, text: str) -> int:
        import tkinter.font as tkfont
        return D.logical(tkfont.Font(self, font=D.font((T.UI, T.F_LABEL, "bold"))).measure(text)) + 8

    def _set_hover(self, index: int):
        if index != self._hover:
            self._hover = index
            self.configure(cursor="hand2" if index >= 0 else "")
            self._redraw()

    def _motion(self, event):
        for index, (left, right) in enumerate(self._boxes):
            if left <= D.logical(event.x) < right:
                self._set_hover(index)
                return
        self._set_hover(-1)

    def _click(self, event):
        for index, (left, right) in enumerate(self._boxes):
            if left <= D.logical(event.x) < right:
                if index != self._active:
                    self._active = index
                    self._redraw()
                    self._on_change(index)
                return


class SignalBars(D.Canvas):
    """数据新鲜度：4 格随最后有效回包时间衰减。"""

    def __init__(self, master, bg=None, width=26, height=16):
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0)
        self._level = -1

    def set_level(self, level: int, color: str | None = None):
        level = max(0, min(4, level))
        if level == self._level and color is None:
            return
        self._level = level
        self.delete("all")
        base = color or (T.JADE if level >= 3 else (T.AMBER if level >= 1 else T.VERM))
        for index in range(4):
            height = 4 + index * 3
            x = index * 6
            fill = base if index < level else T.LINE
            self.create_rectangle(x, 16 - height, x + 4, 16, fill=fill, outline="")


class AgeBar(D.Canvas):
    """横向时效条：满格表示刚回读，右端随时间收缩，超过门限转琥珀/朱砂。"""

    def __init__(self, master, width=180, height=3, bg=None):
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0)
        self._ratio = 0.0
        self._tone = T.JADE
        self.bind("<Configure>", lambda _e: self.set(self._ratio, self._tone, force=True))

    def set(self, ratio: float, tone: str, force=False):
        ratio = max(0.0, min(1.0, ratio))
        if not force and abs(ratio - self._ratio) < 0.01 and tone == self._tone:
            return
        self._ratio, self._tone = ratio, tone
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else 180
        self.create_rectangle(0, 0, w, 3, fill=T.LINE, outline="")
        self.create_rectangle(0, 0, max(2, w * ratio), 3, fill=tone, outline="")


class ShaftView(D.Canvas):
    """1～5 层井道示意。轿厢缓动跟随回读楼层，未回读目标以虚线标注。"""

    FLOORS = (5, 4, 3, 2, 1)
    TOP = 40
    ROW = 42

    def __init__(self, master, width=400, height=None, bg=None):
        height = height or (self.TOP + self.ROW * 5 + 26)
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0)
        self._pos = 0.0
        self._target_pos = 0.0
        self._target = None
        self._direction = "S"
        self._door = "C"
        self._alert_index = None
        self._known = False
        self._stale = False
        self._travel = 1.0
        self._raf = None
        self.bind("<Configure>", lambda _e: self.redraw())

    # ------------------------------------------------------------------
    def set_state(self, floor_index, target=None, direction="S", door="C",
                  alert_index=None, known=True, stale=False):
        self._stale = stale
        if floor_index is None:
            self._known = False
        else:
            self._known = True
            self._target_pos = 4 - (floor_index - 1)
            if abs(self._target_pos - self._pos) > 0.001 and self._raf is None:
                self._travel = 0.0
                self._animate()
        self._target = target
        self._direction = direction
        self._door = door
        self._alert_index = alert_index
        self.redraw()

    def destroy(self):
        if self._raf is not None:
            self.after_cancel(self._raf)
            self._raf = None
        super().destroy()

    def _animate(self):
        delta = self._target_pos - self._pos
        if abs(delta) < 0.004:
            self._pos = self._target_pos
            self._raf = None
            self.redraw()
            return
        self._travel = min(1.0, self._travel + 0.08)
        ease = 1 - (1 - self._travel) ** 3
        self._pos += delta * (0.16 + 0.12 * ease)
        self.redraw()
        self._raf = self.after(16, self._animate)

    # ------------------------------------------------------------------
    def redraw(self):
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else 400
        h = self.logical_height() if self.winfo_height() > 1 else 280
        left, right = 78, w - 62
        row, top = max(30, (h - 78) / 4), 36
        accent = T.AMBER if self._stale else T.JADE

        self.create_text(left - 6, 14, text="楼层井道", anchor="w", fill=T.TEXT_3,
                         font=(T.UI, T.F_MICRO))
        self.create_text(w - 12, 14, text="历史回读" if self._stale else "回读示意 · 非真实速度", anchor="e",
                         fill=T.TEXT_4, font=(T.UI, T.F_MICRO))

        self.create_line(left, top - 10, left, top + row * 4 + 10, fill=T.LINE)
        self.create_line(right, top - 10, right, top + row * 4 + 10, fill=T.LINE)

        for index, floor in enumerate(self.FLOORS):
            y = top + index * row
            active = self._known and abs(self._pos - index) < 0.5
            self.create_line(left, y, right, y, fill=T.JADE_DIM if active else T.LINE)
            self.create_text(left - 14, y, text=f"{floor}F", anchor="e",
                             fill=accent if active else T.TEXT_3,
                             font=(T.NUM_MID, -20 if active else -15))
            self.create_line(right, y, right + 7, y, fill=T.LINE)
            if self._alert_index == floor:
                self.create_polygon(right + 8, y - 5, right + 16, y, right + 8, y + 5,
                                    fill=T.VERM, outline="")
                self.create_text(right + 12, y + 14, text="求援", anchor="w",
                                 fill=T.VERM_SOFT, font=(T.UI, -9))

        if not self._known:
            self.create_text((left + right) / 2, top + row * 2, text="等待设备回读",
                             fill=T.TEXT_3, font=(T.UI, T.F_LABEL))
            self.create_text((left + right) / 2, top + row * 2 + 22,
                             text="不默认设备在 1 层", fill=T.TEXT_4,
                             font=(T.UI, T.F_MICRO))
            return

        target_index = None
        if self._target is not None:
            target_index = 4 - (self._target[0] - 1)
        if target_index is not None and abs(self._pos - target_index) > 0.4:
            ty = top + target_index * row
            for segment in range(int(left + 4), int(right - 4), 11):
                self.create_line(segment, ty, segment + 6, ty, fill=T.TEXT_3)
            self.create_text(right - 6, ty - 13, text="目标", anchor="e",
                             fill=T.TEXT_3, font=(T.UI, T.F_MICRO))

        cy = top + self._pos * row
        cw, ch = 116, 44
        cx = (left + right) / 2
        x0, x1 = cx - cw / 2, cx + cw / 2

        if target_index is not None and abs(self._pos - target_index) > 0.4:
            ty = top + target_index * row
            self.create_line(cx + cw / 2 + 12, cy, cx + cw / 2 + 12, ty,
                             fill=T.JADE_DIM, dash=(2, 3))

        self.create_rectangle(x0, cy - ch / 2, x1, cy + ch / 2, fill=T.CAR_FILL,
                              outline=accent)
        self.create_rectangle(x0 + 4, cy - ch / 2 + 4, x1 - 4, cy + ch / 2 - 4,
                              outline=T.JADE_DIM)
        glyph = {"U": "▲", "D": "▼", "S": "■"}.get(self._direction, "■")
        self.create_text(cx - 26, cy, text=glyph, fill=accent, font=(T.UI, -12))
        self.create_text(cx + 6, cy, text=f"{self.FLOORS[int(round(self._pos))]}F",
                         fill=accent, font=(T.NUM_MID, -20))




class Switch(D.Canvas):
    """34×18 拨动开关；tone 用于区分普通开关与危险开关。"""

    def __init__(self, master, value=False, command=None, bg=None, tone=None):
        super().__init__(master, width=34, height=18, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0)
        self._value = value
        self._command = command
        self._tone = tone or T.JADE
        self.bind("<Button-1>", self._toggle)
        self.bind("<Enter>", lambda _e: self.configure(cursor="hand2"))
        self._redraw()

    def get(self) -> bool:
        return self._value

    def set(self, value: bool):
        if self._value != value:
            self._value = value
            self._redraw()

    def _toggle(self, _event):
        self._value = not self._value
        self._redraw()
        if self._command:
            self._command(self._value)

    def _redraw(self):
        self.delete("all")
        track = self._tone if self._value else T.LINE
        self.create_oval(0, 2, 16, 18, fill=track, outline="")
        self.create_oval(18, 2, 34, 18, fill=track, outline="")
        self.create_rectangle(8, 2, 26, 18, fill=track, outline="")
        knob = 25 if self._value else 9
        self.create_oval(knob - 6, 3, knob + 6, 15,
                         fill=T.BG if self._value else T.TEXT_3, outline="")


class FloorTrace(D.Canvas):
    """近 30 秒楼层轨迹：阶梯线 + 当前点，替代无意义的空白。"""

    def __init__(self, master, width=300, height=88, span=30.0, bg=None):
        super().__init__(master, width=width, height=height, bg=bg or T.PANEL,
                         bd=0, highlightthickness=0)
        self.span = span
        self.samples: list[tuple[float, int]] = []
        self._last: int | None = None

    def push(self, now: float, index: int | None):
        if index is None:
            return
        if self._last == index and self.samples:
            return
        self._last = index
        self.samples.append((now, index))
        self.samples = [s for s in self.samples if now - s[0] <= self.span * 1.4]

    def redraw(self, now: float):
        self.delete("all")
        w = self.logical_width() if self.winfo_width() > 1 else 300
        h = self.logical_height() if self.winfo_height() > 1 else 88
        top, bottom = 12, h - 16
        left, right = 16, w - 10
        for level in range(1, 6):
            y = bottom - (level - 1) * (bottom - top) / 4
            self.create_line(left, y, right, y, fill=T.LINE)
        if not self.samples:
            self.create_text((left + right) / 2, h / 2 - 2, text="等待楼层数据",
                             fill=T.TEXT_4, font=(T.UI, T.F_MICRO))
            return

        def to_xy(ts, index):
            x = left + max(0.0, min(1.0, 1 - (now - ts) / self.span)) * (right - left)
            y = bottom - (index - 1) * (bottom - top) / 4
            return x, y

        points = [to_xy(ts, index) for ts, index in self.samples]
        if len(points) == 1:
            points.insert(0, (left, points[0][1]))
        points[-1] = (right, points[-1][1])
        flat = []
        for i, (x, y) in enumerate(points):
            if i:
                flat.append((x, points[i - 1][1]))
            flat.append((x, y))
        self.create_line(*[c for xy in flat for c in xy], fill=T.TRACE, width=2,
                         joinstyle="miter")
        x, y = points[-1]
        self.create_oval(x - 3, y - 3, x + 3, y + 3, fill=T.JADE, outline="")
        self.create_text(left, h - 3, text=f"−{int(self.span)}s", anchor="sw",
                         fill=T.TEXT_4, font=(T.MONO, -9))
        self.create_text(right, h - 3, text="现在", anchor="se", fill=T.TEXT_4,
                         font=(T.UI, -9))


class ThemeSwatches(D.Canvas):
    """暖白与深灰主题色片。"""

    PITCH = 22

    def __init__(self, master, value, command, bg=None):
        super().__init__(master, width=self.PITCH * len(T.ORDER) + 4, height=20,
                         bg=bg or T.BG, bd=0, highlightthickness=0)
        self._value = value
        self._command = command
        self._hover = -1
        self.bind("<Button-1>", self._click)
        self.bind("<Motion>", self._motion)
        self.bind("<Leave>", lambda _e: self._set_hover(-1))
        self._redraw()

    def set(self, key: str):
        if key != self._value:
            self._value = key
            self._redraw()

    def _center(self, index: int) -> int:
        return 12 + index * self.PITCH

    def _redraw(self):
        self.delete("all")
        for index, key in enumerate(T.ORDER):
            palette = T.THEMES[key]
            active = key == self._value
            x = self._center(index)
            outline = T.JADE if active else (
                T.HOVER_BORDER if index == self._hover else T.LINE)
            self.create_oval(x - 7, 3, x + 7, 17, fill=palette.BG, outline=outline,
                             width=2 if active else 1)
            self.create_oval(x - 3, 7, x + 3, 13, fill=palette.JADE, outline="")

    def _set_hover(self, index: int):
        if index != self._hover:
            self._hover = index
            self.configure(cursor="hand2" if index >= 0 else "")
            self._redraw()

    def _motion(self, event):
        index = int((D.logical(event.x) - 1) // self.PITCH)
        self._set_hover(index if 0 <= index < len(T.ORDER) else -1)

    def _click(self, event):
        index = int((D.logical(event.x) - 1) // self.PITCH)
        if 0 <= index < len(T.ORDER):
            key = T.ORDER[index]
            if key != self._value and self._command:
                self._command(key)
