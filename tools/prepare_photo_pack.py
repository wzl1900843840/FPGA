"""Rebuild the licensed photo pack from the saved real photos, without network access."""
from pathlib import Path
import hashlib, json, struct, datetime
from PIL import Image, ImageOps, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'media/photo_pack_anlogic'
SOURCES = OUT / 'sources'
LOGO = Path('D:/FPGA/anlu/guanfang/lab_ex4_tf/doc/TF卡图片/logo_640x480_24bit_不翻转.bmp')
PHOTOS = [('downtown-city-skyline', '日间城市建筑'),
          ('toronto-stunning-sunset', '城市黄昏'),
          ('mountains-and-blue-lake', '山地湖泊'),
          ('sunlit-forest', '林间自然光')]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    logo_source = LOGO if LOGO.exists() else SOURCES / 'anlogic_original.bmp'
    original_logo = Image.open(logo_source).convert('RGB')
    bbox = ImageChops.difference(original_logo, Image.new('RGB', original_logo.size, 'white')).getbbox()
    logo = original_logo.crop(bbox).convert('RGBA')
    # Remove the original white matte before filtering. Pillow resamples RGBA
    # with premultiplied alpha, retaining the original red/navy colors.
    logo.putdata([(r, g, b, 0 if min(r, g, b) >= 250 else 255)
                  for r, g, b, _ in logo.getdata()])
    logo.thumbnail((64, 41), Image.Resampling.LANCZOS)
    logo.save(OUT / 'anlogic_logo.png')
    records = []
    preview = Image.new('RGB', (1280, 1008), '#162430')
    draw = ImageDraw.Draw(preview)
    for i, (slug, theme) in enumerate(PHOTOS, 1):
        source = SOURCES / (slug + '.jpg')
        meta = json.loads((SOURCES / (slug + '.json')).read_text(encoding='utf-8'))
        image = Image.open(source).convert('RGB')
        w, h = image.size
        crop_w, crop_h = (h * 4 / 3, h) if w / h > 4 / 3 else (w, w * 3 / 4)
        crop = ((w-crop_w)/2, (h-crop_h)/2, (w+crop_w)/2, (h+crop_h)/2)
        photo = image.resize((640, 480), Image.Resampling.LANCZOS, box=crop)
        photo.paste(logo, (16, 16), logo)
        target = OUT / f'PIC{i}.BMP'
        photo.save(target, format='BMP')  # Standard bottom-up BMP; no manual flip.
        data = target.read_bytes()
        signature, size, _, _, offset = struct.unpack_from('<2sIHHI', data)
        dib, width, height, planes, bpp, compression = struct.unpack_from('<IiiHHI', data, 14)
        assert (signature, size, len(data), offset, dib, width, height, planes, bpp, compression) == (
            b'BM', 921654, 921654, 54, 40, 640, 480, 1, 24, 0)
        decoded = Image.open(target).convert('RGB')
        assert decoded.tobytes() == photo.tobytes()
        # Check serialized first/last rows too, independently of Pillow's reader.
        assert data[54:57] == bytes(reversed(photo.getpixel((0, 479))))
        assert data[-3:] == bytes(reversed(photo.getpixel((639, 0))))
        photo.save(OUT / f'PIC{i}_preview.png')
        preview.paste(photo, (((i-1)%2)*640, ((i-1)//2)*504))
        draw.text((((i-1)%2)*640+12, ((i-1)//2)*504+485), f'PIC{i}.BMP', fill='#eef6fa')
        records.append(dict(file=target.name, theme=theme, **meta,
                            source_size=[w, h], crop_box=list(crop), source_sha256=sha(source),
                            size_bytes=len(data), sha256=sha(target), width=width, height=height,
                            bits_per_pixel=bpp, compression=compression, pixel_offset=offset,
                            orientation='standard bottom-up BMP; no additional flip',
                            processing='center crop to 4:3; Lanczos resize; original transparent Anlogic logo at (16,16)',
                            pixel_round_trip=True, serialized_row_orientation=True))
    preview.save(OUT / 'photo_preview.png')
    manifest = dict(created_at=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
                    logo=dict(source=str(LOGO), source_sha256=sha(logo_source), crop_box=bbox,
                              resized_size=logo.size, position=[16, 16],
                              permission='User-supplied logo, used as requested; logo is separate from the photo licenses'),
                    photos=records)
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# 安路 FPGA 照片素材包', '',
             '将 PIC1.BMP～PIC4.BMP 复制到 FAT32 TF 卡根目录。保留项目原有演示素材。',
             '每张 640×480、24 位、BI_RGB 无压缩、54 字节头、921,654 字节。无需额外上下翻转。', '',
             '照片均为来源网站发布的实拍摄影，裁切缩放后加入用户提供的安路 Logo。',
             f'Logo 位于 (16,16)，{logo.width}×{logo.height}（限制框为 64×41），白底透明，图形和颜色来自原始 BMP。', '',
             '| 文件 | 主题 | 作者 | 来源和许可 |', '|---|---|---|---|']
    for p in records:
        license_name = 'CC0 1.0' if p['license_url'].endswith('/creative-commons') else 'Burst Some Rights Reserved'
        lines.append(f"| {p['file']} | {p['theme']} | {p['author']} | [来源]({p['source_page']}) · [{license_name}]({p['license_url']}) |")
    lines += ['', 'CC0 允许复制、修改和再分发。Burst 许可明确允许下载、复制、修改、分发和展示；'
              '本素材包用于免费 FPGA 演示，勿将其作为照片商品出售或汇编成竞争图库。',
              '来源页面、作者和许可页面快照保存在 sources/。完整裁切坐标及 SHA-256 见 manifest.json。',
              '许可仅涉及照片；安路 Logo 由用户提供，其商标权不由照片许可授予。', '',
              '制作：D:/Anaconda/python.exe tools/prepare_photo_pack.py（读取已保存照片，不联网）。',
              'validation.json 记录真实 RTL 解码、界面渲染和端到端链路验证。',
              'ui_preview.png 为实际 RTL 渲染；音轨预览使用模拟 PCM，实板上电时为静音零轴。']
    (OUT / 'README.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    print('PASS photo formats, exact byte counts, pixel round trip, orientation, proportional logo', flush=True)


if __name__ == '__main__':
    main()
