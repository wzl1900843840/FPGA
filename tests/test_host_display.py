"""Native rendering/layout tests. No serial port, worker thread or FPGA access."""
import sys
import tkinter as tk
import tkinter.font as tkfont
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from host_app import display as D
from host_app import theme as T
from host_app.ui import Console
from host_app import protocol as P
from host_app.state import DeviceState
from host_app.widgets import FlatButton, RoundedSelect, ThemeSwatches


class DisplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        D.enable_dpi_awareness()

    def setUp(self):
        self.root = D.create_root()
        self.errors = []
        self.root.report_callback_exception = lambda *err: self.errors.append(str(err))

    def tearDown(self):
        for job in self.root.tk.call("after", "info"):
            self.root.tk.call("after", "cancel", job)
        self.root.destroy()

    def assert_in_parent(self, widget):
        self.assertTrue(widget.winfo_ismapped(), str(widget))
        self.assertLessEqual(widget.winfo_x() + widget.winfo_width(),
                             widget.master.winfo_width() + 2, str(widget))
        self.assertLessEqual(widget.winfo_y() + widget.winfo_height(),
                             widget.master.winfo_height() + 2, str(widget))

    def test_scaled_font_canvas_and_hit_test_share_coordinates(self):
        for scale in (1.0, 1.25, 1.5, 2.0):
            with self.subTest(scale=scale):
                D.SCALE = scale
                calls = []
                button = FlatButton(self.root, "ACK", lambda: calls.append("ack"), 100, 44)
                button.pack()
                self.root.geometry("480x300+0+0")
                self.root.update()
                self.root.update_idletasks()
                self.assertEqual(button.winfo_reqwidth(), D.px(100))
                self.assertEqual(button.winfo_reqheight(), D.px(44))
                item = button.find_all()[-1]
                self.assertAlmostEqual(button.coords(item)[0], button.winfo_width() / 2)
                self.assertEqual(D.font((T.UI, -16))[1], -D.px(16))
                button._keyboard_activate(None)
                button.set_enabled(False)
                button._keyboard_activate(None)
                self.assertEqual(calls, ["ack"])
                swatch = ThemeSwatches(self.root, "paper", calls.append)
                swatch._click(SimpleNamespace(x=D.px(34)))
                self.assertEqual(calls[-1], "graphite")
                swatch.destroy()
                button.destroy()

    def test_rounded_selector_popup_keyboard_cancel_and_disable(self):
        for scale in (1.0, 1.25, 1.5, 2.0):
            with self.subTest(scale=scale):
                D.SCALE = scale
                variable = tk.StringVar(self.root, value="3")
                chosen = []
                box = RoundedSelect(self.root, variable, (1, 2, 3, 4, 5), width=80)
                box.pack(pady=10)
                box.bind("<<ComboboxSelected>>", lambda _e: chosen.append(variable.get()))
                self.root.geometry("600x450+0+0")
                self.root.update()
                box._open()
                self.root.update_idletasks()
                self.assertIsNotNone(box._popup)
                self.assertEqual(box._active, 2)
                self.assertTrue(box._menu.find_withtag("menu_surface"))
                self.assertEqual(len(box._menu.find_withtag("option_text")), 5)
                self.assertEqual(box._row_at(D.px(6 + 36 * 4 + 12)), 4)
                box._menu_key(SimpleNamespace(keysym="Down", state=0))
                box._menu_key(SimpleNamespace(keysym="Return", state=0))
                self.root.update()
                self.assertEqual(variable.get(), "4")
                self.assertEqual(chosen, ["4"])
                self.assertIsNone(box._popup)
                box._open()
                self.root.update_idletasks()
                box._menu_key(SimpleNamespace(keysym="Home", state=0))
                box._menu_key(SimpleNamespace(keysym="Escape", state=0))
                self.assertEqual(variable.get(), "4")
                box._open()
                self.root.update_idletasks()
                box.configure(state="disabled")
                self.assertIsNone(box._popup)
                box._open()
                self.assertIsNone(box._popup)
                box.configure(state="readonly")
                box._open()
                self.root.update_idletasks()
                popup = box._popup
                box._menu_click(SimpleNamespace(x=D.px(20), y=D.px(6 + 18)))
                self.root.update()
                self.assertEqual(variable.get(), "1")
                self.assertFalse(popup.winfo_exists())
                self.assertEqual(chosen, ["4", "1"])
                box._open()
                self.root.update_idletasks()
                box._outside_click(SimpleNamespace(x_root=-100, y_root=-100))
                self.assertIsNone(box._popup)
                self.assertIsNone(self.root.grab_current())
                box._open()
                self.root.update_idletasks()
                box.destroy()
                variable.set("2")  # 销毁后不得残留变量回调或输入捕获
        self.assertFalse(self.errors, self.errors)

    def test_fhd_qhd_layout_theme_and_alarm(self):
        with patch("host_app.ui.HostCore") as core, patch("host_app.ui.config.load",
                return_value={"theme": "graphite"}), patch("host_app.ui.config.save"):
            app = Console(self.root, Path("unused-test-log.jsonl"))
            self.root.update()
            app.snap = {"ts": 10.0, "link": {"state": "online", "sim": True, "age": 0.1},
                        "device": {"floor": "03", "known": True, "floor_age": 0.1,
                                   "alert_src": "elev", "direction": "U", "door": "C",
                                   "floor_src": "elev", "error": "00", "comm": "IDLE"},
                        "demo": {"state": "STOPPED", "target": (5, "U", "C")}}
            for w, h, scale in ((1280, 860, 1.0), (1920, 1080, 1.0), (1800, 1025, 1.25),
                                (2400, 1260, 1.25), (2400, 1260, 1.5), (2560, 1349, 1.25)):
                with self.subTest(viewport=(w, h), scale=scale), patch.object(
                        D, "window_dpi", return_value=round(96 * scale)):
                    D.configure(self.root)
                    app._rebuild()
                    self.root.minsize(D.px(T.WIN_MIN_W), D.px(T.WIN_MIN_H))
                    self.root.geometry(f"{w}x{h}+0+0")
                    self.root.update_idletasks()
                    app._fit_layout()
                    app._render()
                    self.root.update_idletasks()
                    route_bottom = app.demo_route_row.winfo_y() + app.demo_route_row.winfo_height()
                    self.assertGreaterEqual(app.demo_button_row.winfo_y() - route_bottom, D.px(10))
                    header_bottom = app.demo_head.winfo_rooty() + app.demo_head.winfo_height()
                    self.assertGreaterEqual(app.demo_route_row.winfo_rooty() - header_bottom, D.px(8))
                    note_bottom = app.demo_note_label.winfo_rooty() + app.demo_note_label.winfo_height()
                    card_bottom = app.demo_card.winfo_rooty() + app.demo_card.winfo_height()
                    self.assertGreaterEqual(card_bottom - note_bottom, D.px(16))
                    self.assertGreaterEqual(app.target_line.winfo_height(), app.target_line.winfo_reqheight() - 2)
                    self.assertGreaterEqual(app.target_line.winfo_width(), app.target_line.winfo_reqwidth() - 2)
                    for value in app.kv.values():
                        self.assertGreaterEqual(value.winfo_height(), value.winfo_reqheight() - 2)
                    for widget in (app.btn_manual, app.btn_start, app.floor_label, app.btn_present,
                                   app.demo_note_label, *app.route_boxes, *app.route_labels):
                        self.assertTrue(widget.winfo_ismapped(), str(widget))
                        self.assertGreater(widget.winfo_width(), D.px(30))
                        self.assertGreaterEqual(widget.winfo_height(), widget.winfo_reqheight() - 2)
                        self.assert_in_parent(widget)
                        right = widget.winfo_rootx() + widget.winfo_width()
                        self.assertLessEqual(right, self.root.winfo_rootx() + w + 2)
                    for widget in (*app.route_boxes, *app.route_labels, app.port_box):
                        actual = tkfont.Font(root=self.root, font=widget.cget("font"))
                        expected = tkfont.Font(root=self.root, font=D.font((T.UI, T.F_LABEL)))
                        self.assertEqual(actual.actual("family"), expected.actual("family"))
                        self.assertEqual(actual.metrics("linespace"), expected.metrics("linespace"))
                    app._switch_tab(1)
                    self.root.update_idletasks()
                    for widget in (app.raw_entry, app.btn_raw_send, app.raw):
                        self.assert_in_parent(widget)
                        self.assertGreaterEqual(widget.winfo_height(), D.px(20))
                    app.presentation = True
                    app._apply_view_mode()
                    app._fit_layout()
                    self.root.update_idletasks()
                    self.assertTrue(app.presentation_panel.winfo_ismapped())
                    self.assertFalse(app.pages.winfo_ismapped())
                    app.presentation = False
                    app._apply_view_mode()
                    for index, scroll in ((2, app.boot_scroll), (4, app.expert_scroll)):
                        app._switch_tab(index)
                        self.root.update_idletasks()
                        self.assert_in_parent(scroll)
                        self.assertEqual(round(float(scroll.canvas.itemcget(scroll._window, "width"))),
                                         scroll.canvas.winfo_width())
                        scroll.canvas.yview_moveto(1.0)
                        self.root.update_idletasks()
                        self.assertAlmostEqual(scroll.canvas.yview()[1], 1.0, places=2)
            app.pick_floor(4)
            app.pick_dir("D")
            app.pick_door("O")
            app.set_theme("paper")
            self.assertEqual(app.manual_floor, 4)
            self.assertEqual(app.manual_dir.get(), "D")
            self.assertEqual(app.manual_door.get(), "O")
            for theme in T.ORDER:
                app.set_theme(theme)
                app.show_events()
                app._fit_layout()
                app.snap["alarm"] = {"id": "0001", "floor": "03", "ack": "none",
                                     "resolved": False, "acked": False, "duration": 3}
                app._render()
                self.root.update_idletasks()
                self.assertTrue(app.btn_ack.winfo_ismapped())
                self.assertTrue(app.btn_ack._enabled)
                self.assertFalse(app.btn_manual._enabled)
                self.assert_in_parent(app.btn_ack)
                self.assertEqual(app.band.cget("bg"), T.VERM_BG)
                app.btn_ack._keyboard_activate(None)
                self.assertEqual(app.commands.get_nowait(), {"op": "ack"})
                app.snap["alarm"].update(ack="sending")
                app._render()
                self.assertFalse(app.btn_ack._enabled)
                app.snap["alarm"].update(ack="acked", acked=True)
                app._render()
                self.assertEqual(app.btn_ack._text, "已确认")
                self.assertFalse(app.btn_ack._enabled)
                self.assertEqual(app.band.cget("bg"), T.BAND_ACK_BG)
                app.snap["alarm"].update(resolved=True)
                app._render()
                self.root.update_idletasks()
                self.assertFalse(app.band_actions.winfo_manager())
                app._timeline_clear()
                self.assertAlmostEqual(float(app.empty_hint.place_info()["relx"]), 0.5)
            self.assertFalse(self.errors, self.errors)
            core.return_value.start.assert_called_once()

    def test_subtitle_controls_validate_and_queue(self):
        with patch("host_app.ui.HostCore"), patch("host_app.ui.config.load",
                return_value={"theme": "graphite"}), patch("host_app.ui.config.save"):
            app = Console(self.root, Path("unused-test-log.jsonl"))
            app.snap = {"link": {"state": "online"}}
            app._switch_tab(5)
            self.root.update()
            self.assertGreater(app.subtitle_entry.master.master.master.winfo_height(), 100)
            self.assertTrue(app.subtitle_entry.winfo_ismapped())
            self.assertGreater(app.subtitle_entry.winfo_height(), 10)
            for button in app.subtitle_buttons:
                self.assertTrue(button.winfo_ismapped())
                self.assertGreater(button.winfo_height(), 10)
            app._render_raw_controls()
            app.subtitle_text.set("hello")
            app.send_subtitle("text")
            self.assertEqual(app.commands.get_nowait(), {"op": "raw_send", "text": "SUB=HELLO"})
            app.send_subtitle("on")
            self.assertTrue(app.commands.empty())
            app.events.put({"kind": "raw_send_result", "accepted": True, "text": "SUB=HELLO", "note": "已排队"})
            app._drain()
            app.send_subtitle("on")
            self.assertEqual(app.commands.get_nowait(), {"op": "raw_send", "text": "SUB=ON"})
            app.events.put({"kind": "raw_send_result", "accepted": True, "text": "SUB=ON", "note": "已排队"})
            app._drain()
            app.subtitle_text.set("中文")
            app.send_subtitle("text")
            self.assertTrue(app.commands.empty())
            app.replay = True
            app._render_raw_controls()
            self.assertFalse(app.subtitle_buttons[0]._enabled)
            self.assertFalse(self.errors, self.errors)

    def test_custom_route_and_raw_sender_preserve_settings(self):
        with patch("host_app.ui.HostCore"), patch("host_app.ui.config.load",
                return_value={"theme": "graphite"}), patch("host_app.ui.config.save"):
            app = Console(self.root, Path("unused-test-log.jsonl"))
            device = DeviceState()
            device.apply(P.parse_line("ELEV=F03,D=S,DO=C,A=0"), 10.0)
            app.snap = {"ts": 10.1, "link": {"state": "online", "age": 0.1},
                        "device": device.snapshot(10.1),
                        "demo": {"state": "STOPPED"}}
            app.demo_start_floor.set("5")
            app.demo_end_floor.set("2")
            app.demo_mode.set("单程")
            app.raw_command.set("BOOT?")
            for theme in T.ORDER:
                app.set_theme(theme)
                app._render()
                self.root.update_idletasks()
                self.assertEqual((app.demo_start_floor.get(), app.demo_end_floor.get(),
                                  app.demo_mode.get()), ("5", "2", "单程"))
                self.assertEqual(app.raw_command.get(), "BOOT?")
                self.assertTrue(app.btn_start._enabled)
                app.btn_start._keyboard_activate(None)
                self.assertEqual(app.commands.get_nowait(), {"op": "start", "start_floor": 5,
                                                           "end_floor": 2, "mode": "single"})
            app.demo_end_floor.set("5")
            app._route_changed()
            self.assertFalse(app.btn_start._enabled)
            app.demo_end_floor.set("2")
            app.snap["demo"] = {"state": "RUNNING", "running": True,
                                 "start_floor": 5, "end_floor": 2, "mode": "single"}
            app._render()
            self.assertTrue(all(str(box.cget("state")) == "disabled" for box in app.route_boxes))
            self.assertFalse(app.btn_start._enabled)
            app.raw_command.set("ELEV?")
            app.send_raw()
            self.assertEqual(app.commands.get_nowait(), {"op": "raw_send", "text": "ELEV?"})
            self.assertTrue(app._raw_pending)
            app.send_raw()
            self.assertTrue(app.commands.empty())
            app.events.put({"kind": "raw_send_result", "accepted": True,
                            "text": "ELEV?", "note": "已排队"})
            app._drain()
            self.assertFalse(app._raw_pending)
            app.raw_command.set("")
            app._raw_previous()
            self.assertEqual(app.raw_command.get(), "ELEV?")
            app.raw_command.set("中文")
            app.send_raw()
            self.assertTrue(app.commands.empty())
            app.replay = True
            app._render()
            self.assertFalse(app.btn_raw_send._enabled)
            app.raw_command.set("ELEV?")
            app.send_raw()
            self.assertTrue(app.commands.empty())
            self.assertFalse(self.errors, self.errors)

    def test_real_boot_reply_shows_fields_and_allows_explicit_initialization(self):
        with patch("host_app.ui.HostCore"), patch("host_app.ui.config.load",
                return_value={"theme": "graphite"}), patch("host_app.ui.config.save"):
            app = Console(self.root, Path("unused-test-log.jsonl"))
            device = DeviceState()
            device.apply(P.parse_line("ELEV=F00,D=S,DO=M,A=0"), 10.0)
            app.snap = {"ts": 10.1, "link": {"state": "online", "age": 0.1},
                        "device": device.snapshot(10.1),
                        "demo": {"state": "STOPPED"}}
            self.root.update()
            for theme in T.ORDER:
                app.set_theme(theme)
                app._render()
                self.root.update_idletasks()
                self.assertEqual(app.floor_label.cget("text"), "--")
                self.assertEqual(app.readback_tag.cget("text"), "已解析 · 待初始化")
                self.assertIn("F00", app.target_line.cget("text"))
                self.assertIn("停止", app.kv["direction"].cget("text"))
                self.assertEqual(app.kv["door"].cget("text"), "未知")
                self.assertEqual(app.kv["error"].cget("text"), "未提供")
                self.assertTrue(app.btn_start._enabled)
                self.assertEqual(app.btn_start._text, "初始化演示")
                self.assertTrue(app.btn_manual._enabled)
                self.assertFalse(app.shaft._known)
                app.btn_start._keyboard_activate(None)
                self.assertEqual(app.commands.get_nowait(), {"op": "start", "start_floor": 1,
                                                           "end_floor": 5, "mode": "roundtrip"})
            device.apply(P.parse_line("ELEV=F03,D=U,DO=C,A=0"), 10.2)
            app.snap["device"] = device.snapshot(10.3)
            app._render()
            self.assertEqual(app.floor_label.cget("text"), "03")
            self.assertTrue(app.shaft._known)
            device.apply(P.parse_line("ELEV=F03,D=U,DO=C,A=1"), 10.4)
            app.snap["device"] = device.snapshot(10.5)
            app._render()
            self.assertFalse(app.btn_manual._enabled)
            self.assertFalse(app.btn_start._enabled)
            self.assertFalse(self.errors, self.errors)


if __name__ == "__main__":
    unittest.main()
