"""Build the final elevator media pack with exact Chinese safety/information pages."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import datetime, hashlib, json, struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "media" / "elevator_photo_pack"
SRC = OUT / "sources"
LOGO = OUT / "anlogic_logo.png"
FONT = "C:/Windows/Fonts/msyh.ttc"
FONT_BOLD = "C:/Windows/Fonts/msyhbd.ttc"

ITEMS = [
    ("PIC1.BMP", "scene_1.png", (640, 480), "住宅电梯厅日常宣传"),
    ("PIC2.BMP", "safety_background.png", (640, 480), "安全乘梯须知页"),
    ("PIC3.BMP", "floor_background.png", (640, 480), "楼层索引与便民信息页"),
    ("PIC4.BMP", "scene_3.png", (1280, 960), "社区生活日常宣传"),
    ("PIC5.BMP", "alert_background.png", (640, 480), "紧急安抚页"),
]

def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT, size)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fit_4x3(path, size):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    crop_w = min(w, int(h * 4 / 3))
    crop_h = int(crop_w * 3 / 4)
    left, top = (w - crop_w) // 2, (h - crop_h) // 2
    return im.crop((left, top, left + crop_w, top + crop_h)).resize(size, Image.Resampling.LANCZOS), [left, top, left + crop_w, top + crop_h], list(im.size)

def add_logo(im):
    logo = Image.open(LOGO).convert("RGBA")
    if logo.size != (63, 41):
        raise ValueError(f"unexpected logo size: {logo.size}")
    im.paste(logo, (16, 16), logo)

def panel(draw, box, fill=(247, 251, 253, 232), outline=(104, 138, 158, 210), radius=14):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=2)

def draw_no_lean(draw, cx, cy):
    red = (205, 73, 72, 255)
    draw.ellipse((cx - 46, cy - 46, cx + 46, cy + 46), outline=red, width=6)
    draw.line((cx - 26, cy - 25, cx - 26, cy + 28), fill=(53, 77, 91, 255), width=5)
    draw.line((cx + 2, cy - 25, cx + 2, cy + 28), fill=(53, 77, 91, 255), width=5)
    draw.ellipse((cx - 13, cy - 13, cx - 1, cy - 1), fill=(53, 77, 91, 255))
    draw.line((cx - 7, cy, cx + 20, cy + 25), fill=(53, 77, 91, 255), width=5)
    draw.line((cx + 20, cy + 25, cx + 30, cy + 13), fill=(53, 77, 91, 255), width=5)
    draw.line((cx - 53, cy + 53, cx + 53, cy - 53), fill=red, width=8)

def draw_no_jump(draw, cx, cy):
    red = (205, 73, 72, 255)
    navy = (53, 77, 91, 255)
    draw.ellipse((cx - 46, cy - 46, cx + 46, cy + 46), outline=red, width=6)
    draw.ellipse((cx - 8, cy - 29, cx + 8, cy - 13), fill=navy)
    draw.line((cx, cy - 10, cx - 4, cy + 20), fill=navy, width=5)
    draw.line((cx - 4, cy + 1, cx - 25, cy + 12), fill=navy, width=5)
    draw.line((cx - 4, cy + 1, cx + 19, cy - 10), fill=navy, width=5)
    draw.line((cx - 4, cy + 20, cx - 20, cy + 35), fill=navy, width=5)
    draw.line((cx - 4, cy + 20, cx + 18, cy + 32), fill=navy, width=5)
    draw.line((cx - 28, cy + 40, cx + 28, cy + 40), fill=(118, 143, 154, 255), width=4)
    draw.line((cx - 53, cy + 53, cx + 53, cy - 53), fill=red, width=8)

def draw_no_fire_elevator(draw, cx, cy):
    red = (205, 73, 72, 255)
    navy = (53, 77, 91, 255)
    draw.ellipse((cx - 46, cy - 46, cx + 46, cy + 46), outline=red, width=6)
    draw.rectangle((cx - 23, cy - 21, cx + 23, cy + 30), outline=navy, width=4)
    draw.line((cx, cy - 18, cx, cy + 27), fill=navy, width=3)
    draw.polygon([(cx + 1, cy - 33), (cx + 13, cy - 13), (cx + 7, cy - 14), (cx + 17, cy + 2), (cx - 2, cy - 10), (cx - 7, cy - 2)], fill=(225, 153, 57, 255))
    draw.line((cx - 53, cy + 53, cx + 53, cy - 53), fill=red, width=8)

def build_safety(base):
    im = base.convert("RGBA")
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rectangle((0, 82, 640, 480), fill=(244, 249, 251, 120))
    d.text((28, 94), "安全乘梯须知", font=font(27, True), fill=(22, 48, 64, 255))
    d.text((31, 127), "文明乘梯，安全同行", font=font(15), fill=(68, 96, 108, 255))
    boxes = [(18, 158, 202, 344), (228, 158, 412, 344), (438, 158, 622, 344)]
    for box in boxes: panel(d, box)
    draw_no_lean(d, 110, 219); draw_no_jump(d, 320, 219); draw_no_fire_elevator(d, 530, 219)
    labels = [("请勿倚靠", "电梯门"), ("轿厢内禁止", "蹦跳打闹"), ("火灾时请勿", "乘坐电梯")]
    for (a, b), x in zip(labels, (46, 252, 462)):
        d.text((x, 278), a, font=font(16, True), fill=(26, 54, 68, 255))
        d.text((x, 303), b, font=font(16, True), fill=(26, 54, 68, 255))
    d.text((30, 371), "发生异常时，请按下报警按钮并听从工作人员指引", font=font(16, True), fill=(45, 75, 91, 255))
    return Image.alpha_composite(im, layer).convert("RGB")

def build_floor(base):
    im = base.convert("RGBA")
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rectangle((0, 82, 640, 480), fill=(245, 249, 250, 132))
    d.text((28, 94), "楼层索引 / 便民信息", font=font(26, True), fill=(22, 48, 64, 255))
    panel(d, (20, 145, 326, 421), fill=(247, 251, 253, 236))
    panel(d, (344, 145, 620, 421), fill=(247, 251, 253, 236))
    d.text((42, 163), "示例楼层分布", font=font(18, True), fill=(31, 70, 88, 255))
    floors = [("1F", "大堂 / 前台"), ("2F", "物业服务"), ("3F", "社区活动"), ("4F", "健身空间"), ("5F", "会议室")]
    d.line((75, 207, 75, 385), fill=(65, 142, 168, 255), width=4)
    for i, (floor, name) in enumerate(floors):
        y = 211 + i * 36
        d.ellipse((65, y - 7, 85, y + 13), fill=(65, 142, 168, 255))
        d.text((101, y - 8), floor, font=font(15, True), fill=(31, 70, 88, 255))
        d.text((146, y - 8), name, font=font(15), fill=(55, 77, 88, 255))
    d.text((366, 163), "便民联系", font=font(18, True), fill=(31, 70, 88, 255))
    d.rounded_rectangle((366, 203, 598, 278), radius=10, fill=(230, 243, 247, 255))
    d.text((382, 214), "物业电话", font=font(16, True), fill=(31, 70, 88, 255))
    d.text((382, 244), "请按现场配置", font=font(16), fill=(60, 94, 107, 255))
    d.rounded_rectangle((366, 296, 598, 380), radius=10, fill=(246, 237, 215, 255))
    d.text((382, 307), "紧急联系电话", font=font(16, True), fill=(92, 69, 35, 255))
    d.text((382, 338), "110   119   120", font=font(18, True), fill=(92, 69, 35, 255))
    d.text((30, 437), "楼层信息和物业电话可按实际场所更新", font=font(14), fill=(55, 79, 90, 255))
    return Image.alpha_composite(im, layer).convert("RGB")

def build_alert(base):
    im = base.convert("RGBA")
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((22, 91, 354, 386), radius=18, fill=(9, 28, 48, 198), outline=(127, 194, 211, 190), width=2)
    d.ellipse((48, 116, 90, 158), fill=(224, 166, 73, 255))
    d.text((61, 119), "!", font=font(25, True), fill=(18, 49, 64, 255))
    d.text((107, 112), "请保持冷静", font=font(25, True), fill=(235, 247, 249, 255))
    d.text((51, 191), "应急状态已启动", font=font(18, True), fill=(224, 239, 241, 255))
    d.text((51, 239), "请按住报警按钮", font=font(18, True), fill=(224, 239, 241, 255))
    d.text((51, 287), "等待工作人员联系", font=font(18, True), fill=(224, 239, 241, 255))
    d.line((52, 343, 320, 343), fill=(126, 194, 211, 180), width=2)
    d.text((51, 355), "设备保持运行，请勿强行开门", font=font(14), fill=(190, 219, 225, 255))
    return Image.alpha_composite(im, layer).convert("RGB")

def bmp_info(data):
    sig, size, _, _, offset = struct.unpack_from("<2sIHHI", data, 0)
    dib, width, height, planes, bpp, compression = struct.unpack_from("<IiiHHI", data, 14)
    return dict(signature=sig.decode("ascii"), file_size=size, actual_bytes=len(data), pixel_offset=offset,
                dib_size=dib, width=width, height=height, planes=planes, bits_per_pixel=bpp, compression=compression)

def main():
    records = []
    preview = Image.new("RGB", (1280, 960), "#162430")
    preview_draw = ImageDraw.Draw(preview)
    for index, (name, source_name, size, theme) in enumerate(ITEMS, 1):
        base, crop_box, source_size = fit_4x3(SRC / source_name, size)
        if index == 2: image = build_safety(base)
        elif index == 3: image = build_floor(base)
        elif index == 5: image = build_alert(base)
        else: image = base
        add_logo(image)
        target = OUT / name
        image.save(target, format="BMP")
        data = target.read_bytes()
        info = bmp_info(data)
        row_stride = ((size[0] * 3 + 3) // 4) * 4
        expected_bytes = 54 + row_stride * size[1]
        expected = dict(signature="BM", file_size=expected_bytes, actual_bytes=expected_bytes, pixel_offset=54,
                        dib_size=40, width=size[0], height=size[1], planes=1, bits_per_pixel=24, compression=0)
        if info != expected:
            raise AssertionError(f"{target}: {info}")
        if Image.open(target).convert("RGB").tobytes() != image.tobytes():
            raise AssertionError(f"{target}: BMP pixel round trip failed")
        thumb = image.resize((384, 288), Image.Resampling.LANCZOS)
        x = ((index - 1) % 3) * 426 + 20
        y = ((index - 1) // 3) * 480 + 20
        preview.paste(thumb, (x, y))
        label = {1: "PIC1  RESIDENTIAL", 2: "PIC2  SAFETY RULES", 3: "PIC3  FLOOR INFO", 4: "PIC4  COMMUNITY", 5: "PIC5  CALM ALERT"}[index]
        preview_draw.text((x, y + 296), label, fill="#eef6fa")
        records.append(dict(file=name, theme=theme, source_png=f"sources/{source_name}", source_sha256=sha(SRC / source_name),
                            source_size=source_size, crop_box_source=crop_box, output_size=list(size), format=info,
                            logo=dict(file="anlogic_logo.png", position=[16, 16], size=[63, 41]), bmp_sha256=sha(target),
                            processing="center crop 4:3; exact Chinese page rendering where applicable; transparent Anlogic logo overlay",
                            orientation="standard bottom-up BMP; no additional flip", pixel_round_trip=True))
    preview.save(OUT / "preview.png")
    manifest = dict(created_at=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
                    generator=dict(tool="micu-image + Pillow exact layout", model="gpt-image-2.5-flare", requested_size="1536x1024", quality="high"),
                    target=dict(input_for_fpga="PIC4=1280x960; PIC1/PIC2/PIC3/PIC5=640x480", bmp="24-bit RGB, BI_RGB, uncompressed",
                                orientation="bottom-up, no manual flip", decoder_path="ALLOW_2X_SOURCE=1; PIC4 uses 2x2 average downsample to 640x480"),
                    logo=dict(source="media/photo_pack_anlogic/anlogic_logo.png", size=[63, 41], position=[16, 16]), scenes=records)
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    readme = """# 电梯轿厢宣传、便民与应急素材包

最终五张素材按电梯离线信息屏场景组织：两张实拍日常图、两张可读信息页和一张柔和安抚式紧急页。

| 文件 | 用途 | 格式 |
|---|---|---|
| PIC1.BMP | 住宅电梯厅日常宣传 | 640×480 |
| PIC2.BMP | 安全乘梯须知：禁止倚靠、禁止蹦跳、火灾勿乘电梯 | 640×480 |
| PIC3.BMP | 楼层索引、物业服务和紧急联系电话 | 640×480 |
| PIC4.BMP | 社区生活日常宣传 | 1280×960，RTL 自动 2×2 缩小 |
| PIC5.BMP | 蓝灰色、琥珀色提示灯的安抚式紧急页 | 640×480 |

信息页文字和图标由 Pillow 精确绘制，避免生图模型产生错别字；物业电话使用“请按现场配置”占位，紧急电话显示 110、119、120，正式部署前应按现场要求替换。五张图均为 24 位 RGB、BI_RGB 无压缩、标准 54 字节头、bottom-up BMP，并在左上角 (16,16) 叠加 63×41 安路 Logo。

重新生成：`D:/Anaconda/python.exe tools/prepare_elevator_info_pack.py`。完整尺寸、方向、哈希和像素回读记录见 `manifest.json`。
"""
    (OUT / "README.md").write_text(readme, encoding="utf-8")
    print("PASS: final elevator pack built; two exact Chinese info pages and soft alert page verified")

if __name__ == "__main__":
    main()
