from pathlib import Path
from PIL import Image, ImageDraw
import hashlib, json, struct, datetime

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "media" / "elevator_photo_pack"
SOURCE = OUT / "sources"
LOGO_PATH = OUT / "anlogic_logo.png"
SCENES = [
    ("PIC1.BMP", "住宅电梯厅日常宣传", "现代住宅电梯厅，白天"),
    ("PIC2.BMP", "办公园区日常宣传", "办公园区电梯入口，白天"),
    ("PIC3.BMP", "社区生活日常宣传", "社区花园与电梯厅，白天"),
    ("PIC4.BMP", "城市夜景日常宣传", "城市建筑与电梯厅，蓝调时刻"),
    ("PIC5.BMP", "紧急状态页", "电梯安全告警，红黄警示灯"),
]
OUTPUT_SIZES = {
    1: (640, 480),
    2: (640, 480),
    3: (640, 480),
    4: (1280, 960),  # one high-resolution input; keep boot and emergency pages small
    5: (640, 480),
}

def sha256(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def bmp_info(data):
    sig, size, r1, r2, off = struct.unpack_from("<2sIHHI", data, 0)
    dib, w, h, planes, bpp, comp = struct.unpack_from("<IiiHHI", data, 14)
    return dict(signature=sig.decode("ascii"), file_size=size, actual_bytes=len(data),
                pixel_offset=off, dib_size=dib, width=w, height=h, planes=planes,
                bits_per_pixel=bpp, compression=comp)

def main():
    logo = Image.open(LOGO_PATH).convert("RGBA")
    if logo.size != (63, 41):
        raise ValueError(f"unexpected logo size: {logo.size}")
    records = []
    canvas = Image.new("RGB", (1280, 960), "#162430")
    draw = ImageDraw.Draw(canvas)

    for idx, (name, theme, description) in enumerate(SCENES, 1):
        src = SOURCE / f"scene_{idx}.png"
        im = Image.open(src).convert("RGB")
        if im.size != (1536, 1024):
            raise ValueError(f"{src}: expected 1536x1024, got {im.size}")
        crop_w = im.height * 4 // 3
        left = (im.width - crop_w) // 2
        crop_box = [left, 0, left + crop_w, im.height]
        output_size = OUTPUT_SIZES[idx]
        photo = im.crop(crop_box).resize(output_size, Image.Resampling.LANCZOS)
        photo.paste(logo, (16, 16), logo)
        target = OUT / name
        photo.save(target, format="BMP")
        data = target.read_bytes()
        info = bmp_info(data)
        row_stride = ((output_size[0] * 3 + 3) // 4) * 4
        expected_bytes = 54 + row_stride * output_size[1]
        expected = {
            "signature": "BM", "file_size": expected_bytes, "actual_bytes": expected_bytes,
            "pixel_offset": 54, "dib_size": 40, "width": output_size[0],
            "height": output_size[1], "planes": 1, "bits_per_pixel": 24,
            "compression": 0,
        }
        if info != expected:
            raise AssertionError(f"{target}: {info}")
        decoded = Image.open(target).convert("RGB")
        if decoded.size != output_size or decoded.tobytes() != photo.tobytes():
            raise AssertionError(f"{target}: BMP round trip failed")
        if data[54:57] != bytes(reversed(photo.getpixel((0, output_size[1] - 1)))):
            raise AssertionError(f"{target}: bottom row serialization failed")
        if data[-3:] != bytes(reversed(photo.getpixel((output_size[0] - 1, 0)))):
            raise AssertionError(f"{target}: top row serialization failed")

        thumb = photo.resize((256, 192), Image.Resampling.LANCZOS)
        x = ((idx - 1) % 3) * 426
        y = ((idx - 1) // 3) * 480
        canvas.paste(thumb, (x, y))
        draw.rectangle((x, y + 192, x + 256, y + 218), fill="#162430")
        preview_label = {
            1: "PIC1  DAILY - RESIDENTIAL",
            2: "PIC2  DAILY - OFFICE PARK",
            3: "PIC3  DAILY - COMMUNITY",
            4: "PIC4  DAILY - CITY NIGHT",
            5: "PIC5  EMERGENCY - SAFETY",
        }[idx]
        draw.text((x + 8, y + 198), preview_label, fill="#eef6fa")

        records.append({
            "file": name, "theme": theme, "description": description,
            "source_png": str(src.relative_to(OUT)).replace("\\", "/"),
            "source_sha256": sha256(src), "source_size": list(im.size),
            "crop_box_source": crop_box, "output_size": list(output_size),
            "logo": {"file": "anlogic_logo.png", "position": [16, 16], "size": [63, 41]},
            "format": info, "bmp_sha256": sha256(target),
            "processing": "center crop 4:3, Lanczos resize to 1280x960, transparent Anlogic logo overlay",
            "orientation": "standard bottom-up BMP; no additional flip",
            "pixel_round_trip": True,
        })

    draw.rectangle((0, 480, 1279, 959), fill="#162430")
    for idx in (4, 5):
        name, theme, description = SCENES[idx - 1]
        photo = Image.open(OUT / name).convert("RGB").resize((384, 288), Image.Resampling.LANCZOS)
        x = 128 + (idx - 4) * 512
        y = 540
        canvas.paste(photo, (x, y))
        preview_label = "PIC4  DAILY - CITY NIGHT" if idx == 4 else "PIC5  EMERGENCY - SAFETY"
        draw.text((x + 8, y + 296), preview_label, fill="#eef6fa")
    canvas.save(OUT / "preview.png")

    manifest = {
        "created_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        "generator": {"tool": "micu-image", "model": "gpt-image-2.5-flare",
                      "requested_size": "1536x1024", "quality": "high"},
        "target": {"input_for_fpga": "PIC4=1280x960; PIC1/PIC2/PIC3/PIC5=640x480",
                   "bmp": "24-bit RGB, BI_RGB, uncompressed", "pixel_offset": 54,
                   "orientation": "bottom-up, no manual flip",
                   "decoder_path": "ALLOW_2X_SOURCE=1; PIC4 uses 2x2 average downsample to 640x480"},
        "logo": {"source": "media/photo_pack_anlogic/anlogic_logo.png",
                 "size": [63, 41], "position": [16, 16],
                 "note": "User-provided Anlogic logo with transparent white matte removed."},
        "scenes": records,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    readme = """# 电梯轿厢宣传与应急素材包

本目录包含四张日常宣传图和一张紧急状态图，针对当前电梯轿厢离线宣传屏演示场景制作。

| 文件 | 用途 |
|---|---|
| PIC1.BMP | 住宅电梯厅日常宣传 |
| PIC2.BMP | 办公园区电梯入口日常宣传 |
| PIC3.BMP | 社区花园与电梯厅日常宣传 |
| PIC4.BMP | 城市夜景日常宣传 |
| PIC5.BMP | 紧急状态备用页 |

## FPGA 输入格式

- PIC4.BMP 为 1280×960、其余四张为 640×480；均为 24 位 RGB、BI_RGB 无压缩 BMP
- 标准 54 字节 BMP/DIB 头，正高度表示 bottom-up
- PIC4.BMP 为 3,686,454 字节；其余每张为 921,654 字节
- 左上角叠加安路 Logo，位置 (16,16)，尺寸 63×41
- 当前 RTL 以 `ALLOW_2X_SOURCE=1` 对 PIC4 进行 2×2 平均缩小，写入 640×480 SDRAM bank
- PIC5 可作为告警页，不参与普通四格缩略图

## 生成与校验

源图由 `micu-image` 生成，保存于 `sources/`；`tools/prepare_elevator_photo_pack.py` 完成本地裁切、Logo 叠加、BMP 导出及像素回读校验。`manifest.json` 记录每张图的源图哈希、裁切坐标、BMP 格式和 SHA-256。
"""
    (OUT / "README.md").write_text(readme, encoding="utf-8")
    print("PASS: five BMP files (one 1280x960, four 640x480), logo overlay, format and pixel round-trip verified")

if __name__ == "__main__":
    main()
