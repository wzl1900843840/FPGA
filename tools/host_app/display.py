"""Native DPI rendering for the host UI, using 96-DPI logical units.

Only these explicitly imported widgets are adapted. Tkinter is not patched.
Fonts and canvas primitives are rendered at the final physical pixel size.
"""
from __future__ import annotations

import ctypes
import sys
import tkinter as tk
from tkinter import ttk

SCALE = 1.0
AWARENESS = "platform"


def enable_dpi_awareness():
    """Call before Tk creates the first HWND; packaged EXEs should use a manifest."""
    global AWARENESS
    if sys.platform != "win32":
        return AWARENESS
    try:
        setter = ctypes.windll.user32.SetProcessDpiAwarenessContext
        setter.argtypes = [ctypes.c_void_p]
        setter.restype = ctypes.c_bool
        if setter(ctypes.c_void_p(-4)):
            AWARENESS = "per-monitor-v2"
            return AWARENESS
    except (AttributeError, OSError):
        pass
    try:
        if ctypes.windll.shcore.SetProcessDpiAwareness(2) == 0:
            AWARENESS = "per-monitor"
            return AWARENESS
    except (AttributeError, OSError):
        pass
    try:
        if ctypes.windll.user32.SetProcessDPIAware():
            AWARENESS = "system"
        else:
            AWARENESS = "already-configured"
    except (AttributeError, OSError):
        AWARENESS = "unavailable"
    return AWARENESS


def window_dpi(root):
    if sys.platform == "win32":
        try:
            getter = ctypes.windll.user32.GetDpiForWindow
            getter.argtypes = [ctypes.c_void_p]
            getter.restype = ctypes.c_uint
            return getter(root.winfo_id()) or 96
        except (AttributeError, OSError):
            pass
    return round(root.winfo_fpixels("1i"))


def configure(root):
    global SCALE
    value = min(3.0, max(1.0, window_dpi(root) / 96.0))
    changed = abs(value - SCALE) > 0.01
    SCALE = value
    root.tk.call("tk", "scaling", SCALE * 96.0 / 72.0)
    return changed


def create_root():
    enable_dpi_awareness()
    root = tk.Tk()
    configure(root)
    return root


def px(value):
    if isinstance(value, (tuple, list)):
        return tuple(px(v) for v in value)
    return round(value * SCALE) if isinstance(value, (int, float)) else value


def logical(value):
    return value / SCALE


def font(value):
    if isinstance(value, (tuple, list)) and len(value) > 1:
        result = list(value)
        if isinstance(result[1], (int, float)) and result[1] < 0:
            result[1] = -max(1, px(-result[1]))
        return tuple(result)
    return value


class _Geometry:
    _pixel_dimensions = False

    def __init__(self, master=None, **kwargs):
        super().__init__(master, **self._scale_options(kwargs))

    def _scale_options(self, options):
        result = dict(options)
        dimensions = {"padx", "pady", "borderwidth", "bd", "highlightthickness", "wraplength"}
        if self._pixel_dimensions:
            dimensions.update(("width", "height"))
        for key in dimensions.intersection(result):
            result[key] = px(result[key])
        if "font" in result:
            result["font"] = font(result["font"])
        return result

    def configure(self, cnf=None, **kwargs):
        if isinstance(cnf, str) or (cnf is None and not kwargs):
            return super().configure(cnf)
        return super().configure(self._scale_options({**(cnf or {}), **kwargs}))

    config = configure

    def pack_configure(self, cnf=None, **kwargs):
        options = {**(cnf or {}), **kwargs}
        for key in ("padx", "pady", "ipadx", "ipady"):
            if key in options:
                options[key] = px(options[key])
        return super().pack_configure(options)

    pack = pack_configure

    def grid_configure(self, cnf=None, **kwargs):
        options = {**(cnf or {}), **kwargs}
        for key in ("padx", "pady", "ipadx", "ipady"):
            if key in options:
                options[key] = px(options[key])
        return super().grid_configure(options)

    grid = grid_configure

    def place_configure(self, cnf=None, **kwargs):
        options = {**(cnf or {}), **kwargs}
        for key in ("x", "y", "width", "height"):
            if key in options:
                options[key] = px(options[key])
        return super().place_configure(options)

    place = place_configure

    def columnconfigure(self, index, cnf=None, **kwargs):
        options = {**(cnf or {}), **kwargs}
        for key in ("minsize", "pad"):
            if key in options:
                options[key] = px(options[key])
        return super().columnconfigure(index, options)

    def rowconfigure(self, index, cnf=None, **kwargs):
        options = {**(cnf or {}), **kwargs}
        for key in ("minsize", "pad"):
            if key in options:
                options[key] = px(options[key])
        return super().rowconfigure(index, options)


class Frame(_Geometry, tk.Frame):
    _pixel_dimensions = True


class Label(_Geometry, tk.Label):
    pass


class Text(_Geometry, tk.Text):
    pass


class Entry(_Geometry, tk.Entry):
    pass


class Combobox(_Geometry, ttk.Combobox):
    pass


class Treeview(_Geometry, ttk.Treeview):
    def column(self, column, option=None, **kwargs):
        for key in ("width", "minwidth"):
            if key in kwargs:
                kwargs[key] = px(kwargs[key])
        return super().column(column, option, **kwargs)


class Scrollbar(_Geometry, ttk.Scrollbar):
    pass


class Canvas(_Geometry, tk.Canvas):
    _pixel_dimensions = True

    def logical_width(self):
        return logical(self.winfo_width())

    def logical_height(self):
        return logical(self.winfo_height())

    def _draw(self, method, coords, options):
        def flatten(values):
            for value in values:
                if isinstance(value, (tuple, list)):
                    yield from flatten(value)
                else:
                    yield value
        options = dict(options)
        for key in ("width", "activewidth", "disabledwidth", "dashoffset"):
            if key in options:
                options[key] = px(options[key])
        if "dash" in options and isinstance(options["dash"], (tuple, list)):
            options["dash"] = px(options["dash"])
        if "font" in options:
            options["font"] = font(options["font"])
        return method(*(float(v) * SCALE for v in flatten(coords)), **options)

    def create_rectangle(self, *coords, **options):
        return self._draw(super().create_rectangle, coords, options)

    def create_line(self, *coords, **options):
        return self._draw(super().create_line, coords, options)

    def create_oval(self, *coords, **options):
        return self._draw(super().create_oval, coords, options)

    def create_polygon(self, *coords, **options):
        return self._draw(super().create_polygon, coords, options)

    def create_text(self, *coords, **options):
        return self._draw(super().create_text, coords, options)

    def rounded_rect(self, x0, y0, x1, y1, radius=12, **options):
        radius = max(0, min(radius, (x1 - x0) / 2, (y1 - y0) / 2))
        points = (x0 + radius, y0, x1 - radius, y0, x1, y0,
                  x1, y0 + radius, x1, y1 - radius, x1, y1,
                  x1 - radius, y1, x0 + radius, y1, x0, y1,
                  x0, y1 - radius, x0, y0 + radius, x0, y0)
        return self.create_polygon(points, smooth=True, splinesteps=32, **options)
