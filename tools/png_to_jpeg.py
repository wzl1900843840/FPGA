"""Convert the three 六观 submission screenshots from PNG to real JPEG.

Outputs stay in the same folder, keep the original base names, and are verified to be
真 JPEG（魔数 FF D8）+ 小于 1MB。不修改、不删除原始 PNG。
"""
from pathlib import Path
import sys

try:
    from PIL import Image
except ImportError:
    print("缺少 Pillow，请先运行：pip install Pillow")
    sys.exit(1)

FOLDER = Path(r"C:\Users\wzl123\Desktop\hbws_competition\比赛提交\最终提交物\官网上传版")
FILES = [
    "01-AI批改工作台.png",
    "02-编程答疑.png",
    "03.错题总结与练习助手智能体.png",
]
LIMIT_BYTES = 1024 * 1024


def save_under_limit(image, target):
    """Save as baseline JPEG, dropping quality until it fits under 1MB."""
    for quality in (92, 88, 85, 80, 75, 70, 65, 60):
        image.save(target, format="JPEG", quality=quality, optimize=True, progressive=False)
        size = target.stat().st_size
        if size <= LIMIT_BYTES:
            return quality, size
    return quality, target.stat().st_size


def main():
    missing = [name for name in FILES if not (FOLDER / name).is_file()]
    if missing:
        print("找不到文件：")
        for name in missing:
            print("  " + name)
        return 1

    for name in FILES:
        source = FOLDER / name
        target = source.with_suffix(".jpg")
        with Image.open(source) as image:
            if image.mode not in ("RGB", "L"):
                # JPEG 不支持透明通道，先合成到白底，避免透明区域变黑
                background = Image.new("RGB", image.size, (255, 255, 255))
                converted = image.convert("RGBA")
                background.paste(converted, mask=converted.split()[-1])
                image = background
            else:
                image = image.convert("RGB")
            quality, size = save_under_limit(image, target)
        head = target.read_bytes()[:2]
        ok = head == b"\xff\xd8" and size <= LIMIT_BYTES
        print(f"{target.name:44s} {image.size[0]}x{image.size[1]}  "
              f"{size/1024:7.1f} KB  quality={quality}  "
              f"{'OK' if ok else '需检查'}")
    print("\n原始 PNG 未改动。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
