"""启动梯间守望上位机。

双击 `start_console.cmd` 时由它调用；也可直接 `python tools/launch_console.py`。
职责：挑一个带 tkinter 的解释器，优先用 pythonw 起窗口（不留黑框），
启动前先做一次导入自检，把失败原因留在控制台而不是无声退出。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ENTRY = HERE / "stairwell_watch.py"
LOG = ROOT / "logs" / "host_console.jsonl"

CANDIDATES = (
    Path("D:/Anaconda/python.exe"),
    Path("D:/Python/Python3.13.4/python.exe"),
)


def has_tkinter(executable: str) -> bool:
    try:
        result = subprocess.run(
            [executable, "-c", "import tkinter"],
            capture_output=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def pythonw_of(executable: str) -> str | None:
    path = Path(executable)
    if not path.is_absolute():
        return "pythonw"
    windowless = path.with_name("pythonw.exe")
    return str(windowless) if windowless.exists() else None


def check() -> int:
    print(f"工程目录 : {ROOT}")
    print(f"入口脚本 : {ENTRY}")
    print(f"当前解释器: {sys.executable}")
    print(f"tkinter  : {'可用' if has_tkinter(sys.executable) else '不可用'}")
    for candidate in CANDIDATES:
        if candidate.exists():
            print(f"候选     : {candidate}  "
                  f"tkinter={'可用' if has_tkinter(str(candidate)) else '不可用'}")
    print(f"日志     : {LOG}")
    return 0


def main() -> int:
    if "--check" in sys.argv:
        return check()
    if not ENTRY.exists():
        print(f"找不到入口脚本：{ENTRY}")
        return 1

    if not has_tkinter(sys.executable):
        for candidate in CANDIDATES:
            if candidate.exists() and has_tkinter(str(candidate)):
                print(f"当前解释器缺少 tkinter，改用 {candidate}")
                return subprocess.call([str(candidate), str(Path(__file__).resolve()),
                                        *sys.argv[1:]])
        print("找不到带 tkinter 的 Python。请安装 Python 3.9+ 并勾选 tcl/tk，")
        print("或修改 start_console.cmd 里的解释器路径。")
        return 1

    # 导入自检：模块级错误在这里暴露，而不是让 pythonw 静默退出
    probe = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, r'%s'); import host_app.ui" % HERE],
        capture_output=True, text=True,
    )
    if probe.returncode != 0:
        print("上位机模块导入失败：")
        print(probe.stderr.strip() or probe.stdout.strip())
        return 1

    LOG.parent.mkdir(parents=True, exist_ok=True)
    windowless = pythonw_of(sys.executable)
    command = [windowless or sys.executable, str(ENTRY)]
    if windowless:
        # 与控制台脱钩，否则 cmd 关窗时会把窗口进程一起带走
        flags = 0
        if sys.platform == "win32":
            flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        subprocess.Popen(command, cwd=str(ROOT), close_fds=True, creationflags=flags)
        print(f"已启动上位机（解释器：{windowless}）")
        print(f"日志目录：{LOG.parent}")
        return 0
    return subprocess.call(command, cwd=str(ROOT))


if __name__ == "__main__":
    sys.exit(main())
