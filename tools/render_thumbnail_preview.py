"""Render the production centered thumbnail cache and focus border from real photos."""
from pathlib import Path
import subprocess
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/results/thumbnail_center'
OUT.mkdir(parents=True, exist_ok=True)
fixture = OUT / 'photos.hex'
with fixture.open('w', encoding='ascii') as handle:
    for n in range(1, 5):
        photo = Image.open(ROOT / f'media/photo_pack_anlogic/PIC{n}.BMP').convert('RGB')
        assert photo.size == (640, 480)
        pixels = photo.get_flattened_data() if hasattr(photo, 'get_flattened_data') else photo.getdata()
        handle.writelines(f'{r:02x}{g:02x}{b:02x}\n' for r, g, b in pixels)
binary = OUT / 'preview.vvp'
rtl = ROOT / 'src/user_source/rtl'
subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'tb_thumbnail_preview',
                '-o', str(binary), str(ROOT / 'tests/tb_thumbnail_preview.v'),
                str(rtl / 'thumbnail_cache_builder.v'), str(rtl / 'thumbnail_layout.v')], check=True)
ppm = OUT / 'centered.ppm'
result = subprocess.run(['D:/iverilog/bin/vvp.exe', str(binary),
                         '+PHOTOS=' + str(fixture), '+OUTPUT=' + str(ppm)],
                        capture_output=True, text=True, timeout=180, check=True)
(OUT / 'preview.log').write_text(result.stdout + result.stderr, encoding='utf-8')
if 'PASS thumbnail preview:' not in result.stdout:
    raise RuntimeError(result.stdout + result.stderr)
Image.open(ppm).save(OUT / 'centered.png')
print(result.stdout.strip())
print(OUT / 'centered.png')
