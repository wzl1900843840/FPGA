"""界面设计令牌与主题。

颜色集中在这里定义，`apply(name)` 会把当前主题写回模块级变量，
因此 `theme.PANEL` 这类引用在切换主题后自动指向新值。
Tk 没有样式表，已创建的控件不会自己变色，切换时由界面层重建控件树。
"""
from __future__ import annotations

from dataclasses import dataclass, fields


@dataclass(frozen=True)
class Palette:
    key: str
    label: str
    note: str
    dark: bool
    # 表面
    BG: str
    SURFACE: str
    PANEL: str
    PANEL_HI: str
    PANEL_TOP: str
    STRIPE: str
    # 分隔线
    LINE: str
    LINE_SOFT: str
    HOVER_BORDER: str
    # 文字
    TEXT: str
    TEXT_2: str
    TEXT_3: str
    TEXT_4: str
    # 语义色
    JADE: str
    JADE_DIM: str
    JADE_BG: str
    JADE_HOVER: str
    TRACE: str
    VERM: str
    VERM_SOFT: str
    VERM_BG: str
    VERM_HOVER: str
    RING_MUTED: str
    AMBER: str
    AMBER_BG: str
    # 构件
    CAR_FILL: str
    BTN_ON_ACCENT: str
    BTN_ON_DANGER: str
    BAND_ACK_BG: str
    WIRE_BORDER: str
    WIRE_HOVER: str


GRAPHITE = Palette(
    key="graphite", label="深灰", note="中性深灰与柔白文字，适合日常值守",
    dark=True,
    BG="#181818", SURFACE="#1D1D1D", PANEL="#242424", PANEL_HI="#303030",
    PANEL_TOP="#292929", STRIPE="#212121",
    LINE="#383838", LINE_SOFT="#2E2E2E", HOVER_BORDER="#72726E",
    TEXT="#F2F2EE", TEXT_2="#D3D3CE", TEXT_3="#AEAEA7", TEXT_4="#90908B",
    JADE="#5CC0A2", JADE_DIM="#2A5B4E", JADE_BG="#0E1C19", JADE_HOVER="#71D2B5",
    TRACE="#4BBAA2",
    VERM="#E2544A", VERM_SOFT="#F08078", VERM_BG="#241110", VERM_HOVER="#ED6860",
    RING_MUTED="#77332F",
    AMBER="#D8A24A", AMBER_BG="#1A1409",
    CAR_FILL="#29332E", BTN_ON_ACCENT="#08120F", BTN_ON_DANGER="#FFF6F4",
    BAND_ACK_BG="#2B261D", WIRE_BORDER="#50504D", WIRE_HOVER="#777771",
)

PAPER = Palette(
    key="paper", label="暖白", note="暖白与中性灰，适合桌面与答辩投屏",
    dark=False,
    BG="#F4F4F0", SURFACE="#FAFAF7", PANEL="#FFFFFF", PANEL_HI="#EFEFEC",
    PANEL_TOP="#F3F3F0", STRIPE="#FBFBF9",
    LINE="#DEDED8", LINE_SOFT="#EBEBE6", HOVER_BORDER="#ACADA5",
    TEXT="#252622", TEXT_2="#4D4F48", TEXT_3="#6B6E64", TEXT_4="#868A7D",
    JADE="#25775D", JADE_DIM="#BAD6CA", JADE_BG="#EAF4EE", JADE_HOVER="#31876C",
    TRACE="#3E9C82",
    VERM="#BE3A2C", VERM_SOFT="#A83326", VERM_BG="#FBEDE9", VERM_HOVER="#CF4436",
    RING_MUTED="#D9A49C",
    AMBER="#8F6412", AMBER_BG="#FBF1DE",
    CAR_FILL="#EEF5F0", BTN_ON_ACCENT="#FFFFFF", BTN_ON_DANGER="#FFFFFF",
    BAND_ACK_BG="#FBF3E2", WIRE_BORDER="#C9C3B6", WIRE_HOVER="#B4AE9F",
)

INK = Palette(
    key="ink", label="墨蓝", note="高对比冷色，适合投影与远距离观看",
    dark=True,
    BG="#05080F", SURFACE="#0A111C", PANEL="#0E1724", PANEL_HI="#16222F",
    PANEL_TOP="#1A2735", STRIPE="#0C131D",
    LINE="#31465C", LINE_SOFT="#23364A", HOVER_BORDER="#617D98",
    TEXT="#F3F7FB", TEXT_2="#CDDCEC", TEXT_3="#ACBFD2", TEXT_4="#8FA6BD",
    JADE="#4ECDE4", JADE_DIM="#1D5A6B", JADE_BG="#0B2430", JADE_HOVER="#6FDCEE",
    TRACE="#2A7E90",
    VERM="#FF6157", VERM_SOFT="#FF8C84", VERM_BG="#2A1216", VERM_HOVER="#FF7A71",
    RING_MUTED="#7A3A36",
    AMBER="#F2B63C", AMBER_BG="#1C1608",
    CAR_FILL="#0D2836", BTN_ON_ACCENT="#04141A", BTN_ON_DANGER="#1A0806",
    BAND_ACK_BG="#1A1710", WIRE_BORDER="#34465A", WIRE_HOVER="#44596E",
)

THEMES = {palette.key: palette for palette in (PAPER, GRAPHITE)}
ORDER = ("paper", "graphite")
DEFAULT = "graphite"

_current = GRAPHITE
DARK = True


def apply(key: str) -> Palette:
    """把主题写回模块级变量；返回实际生效的主题。"""
    global _current, DARK
    _current = THEMES.get("graphite" if key == "ink" else key, THEMES[DEFAULT])
    DARK = _current.dark
    for field in fields(Palette):
        globals()[field.name] = getattr(_current, field.name)
    return _current


def current() -> Palette:
    return _current


def next_key(key: str) -> str:
    index = ORDER.index(key) if key in ORDER else 0
    return ORDER[(index + 1) % len(ORDER)]


# 字体（与主题无关）
UI = "Microsoft YaHei UI"
NUM = "Bahnschrift"
NUM_MID = "Bahnschrift"
MONO = "Cascadia Mono"

# 字号（负数 = 像素高度）
F_DISPLAY = -92
F_H1 = -18
F_H2 = -18
F_BODY = -17
F_LABEL = -16
F_MICRO = -14
F_MONO = -14

# 间距与布局
GUTTER = 18
CARD_PAD = 16
WIN_W, WIN_H = 1800, 1000
WIN_MIN_W, WIN_MIN_H = 1240, 820
TOPBAR_H = 84
ALARM_H = 124
MAIN_H = 460
TABBAR_H = 48
STATUS_H = 42


def button_tone(kind: str) -> dict:
    """按钮配色随主题走，避免把深色专用的前景色写死。"""
    table = {
        "primary": {"fill": TEXT, "fg": PANEL, "border": TEXT,
                    "hover": TEXT_2, "hover_border": TEXT_2, "hover_fg": None},
        "danger": {"fill": VERM, "fg": BTN_ON_DANGER, "border": VERM,
                   "hover": VERM_HOVER, "hover_border": VERM_HOVER, "hover_fg": None},
        "ghost": {"fill": None, "fg": TEXT, "border": LINE,
                  "hover": None, "hover_border": HOVER_BORDER, "hover_fg": None},
        "quiet": {"fill": None, "fg": TEXT_3, "border": None,
                  "hover": None, "hover_border": None, "hover_fg": TEXT},
        "wire": {"fill": None, "fg": TEXT, "border": WIRE_BORDER,
                 "hover": None, "hover_border": WIRE_HOVER, "hover_fg": None},
    }
    return table.get(kind, table["ghost"])


def apply_window_chrome(root, dark: bool | None = None) -> None:
    """Windows 10/11 标题栏跟随主题；失败时静默保留系统默认。"""
    try:
        import ctypes

        root.update_idletasks()
        from ctypes import wintypes
        get_parent = ctypes.windll.user32.GetParent
        get_parent.argtypes = [wintypes.HWND]
        get_parent.restype = wintypes.HWND
        hwnd = get_parent(root.winfo_id()) or root.winfo_id()
        setter = ctypes.windll.dwmapi.DwmSetWindowAttribute
        setter.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
        setter.restype = ctypes.c_long
        value = ctypes.c_int(1 if (DARK if dark is None else dark) else 0)
        for attribute in (20, 19):
            setter(
                hwnd, attribute, ctypes.byref(value), ctypes.sizeof(value)
            )
    except Exception:
        pass


apply(DEFAULT)
