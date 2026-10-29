"""Add the project's original Anlogic logo to an existing FPGA BMP pack.

Back up every original before replacement. Keep the bottom-up RGB24 BMP
contract and verify that pixels outside the logo rectangle never change.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import io
import json
import os
import struct
import zipfile

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def bmp_info(data):
    sig, size, _, _, offset = struct.unpack_from('<2sIHHI', data)
    dib, w, h, planes, bpp, compression = struct.unpack_from('<IiiHHI', data, 14)
    info = dict(signature=sig.decode('ascii'), file_size=size, actual_bytes=len(data),
                pixel_offset=offset, dib_size=dib, width=w, height=h, planes=planes,
                bpp=bpp, compression=compression, bottom_up=h > 0)
    if (sig != b'BM' or (w, h) not in ((640, 480), (1280, 960))
            or dib != 40 or offset != 54 or planes != 1 or bpp != 24
            or compression != 0 or size != len(data) or len(data) != 54+w*h*3):
        raise ValueError('Unsupported FPGA BMP format: '+str(info))
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--logo', type=Path, default=ROOT/'media/elevator_photo_pack/anlogic_logo.png')
    args = parser.parse_args()
    folder, logo_path = args.directory.resolve(), args.logo.resolve()
    logo_bytes = logo_path.read_bytes()
    logo = Image.open(io.BytesIO(logo_bytes)).convert('RGBA')
    if logo.size != (63, 41):
        raise ValueError('Expected the original 63x41 logo')
    manifest_path = folder/'manifest.json'
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    if not isinstance(manifest, list):
        raise ValueError('Expected a list manifest')
    paths = [folder/f'PIC{i}.BMP' for i in range(1, 6)]
    snapshots = {p.name: p.read_bytes() for p in paths}
    snapshots['manifest.json'] = manifest_bytes
    records, candidates = [], {}
    for p in paths:
        original = snapshots[p.name]
        before_info = bmp_info(original)
        photo = Image.open(io.BytesIO(original)).convert('RGB')
        scale = photo.width//640
        size = (63*scale, 41*scale)
        position = (16*scale, 16*scale)
        box = (*position, position[0]+size[0], position[1]+size[1])
        stamp = logo if scale == 1 else logo.resize(size, Image.Resampling.NEAREST)
        result = photo.copy()
        result.paste(stamp, position, stamp)
        expected_outside = photo.copy()
        expected_outside.paste(result.crop(box), position)
        if expected_outside.tobytes() != result.tobytes():
            raise AssertionError('Pixel changes outside logo rectangle')
        stream = io.BytesIO()
        result.save(stream, format='BMP')
        data = stream.getvalue()
        if bmp_info(data) != before_info:
            raise AssertionError('BMP format changed')
        if Image.open(io.BytesIO(data)).convert('RGB').tobytes() != result.tobytes():
            raise AssertionError('BMP pixel round trip failed')
        if scale == 2:
            output_logo = result.crop(box).resize((63, 41), Image.Resampling.BOX)
            reference = photo.crop(box).resize((63, 41), Image.Resampling.BOX)
            reference.paste(logo, (0, 0), logo)
            if max(abs(a-b) for a,b in zip(output_logo.tobytes(), reference.tobytes())) > 1:
                raise AssertionError('2x decoder logo differs from display-size reference')
        candidates[p.name] = data
        records.append(dict(file=p.name, before_sha256=sha(original), sha256=sha(data),
                            format=before_info, logo=dict(source=str(logo_path), sha256=sha(logo_bytes),
                            source_position=list(position), source_size=list(size),
                            display_position=[16,16], display_size=[63,41]),
                            outside_logo_unchanged=True, pixel_round_trip=True))
    by_name = {r['file']:r for r in records}
    for item in manifest:
        name = Path(item['file']).name
        if name in by_name:
            record = by_name[name]
            item.update(sha256=record['sha256'], logo=record['logo'])
    now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    backup = folder.parent/('bmp_fpga_before_anlogic_'+now.strftime('%Y%m%d_%H%M%S_%f')+'.zip')
    with zipfile.ZipFile(backup, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name, data in snapshots.items():
            archive.writestr(name, data)
    with zipfile.ZipFile(backup) as archive:
        if archive.testzip() is not None:
            raise AssertionError('Backup CRC verification failed')
        for name, data in snapshots.items():
            if archive.read(name) != data:
                raise AssertionError('Backup bytes mismatch: '+name)
    # Refuse a concurrent image edit after validation and backup.
    for name, data in snapshots.items():
        if (folder/name).read_bytes() != data:
            raise RuntimeError('Source changed during processing: '+name)
    for name, data in candidates.items():
        temp = folder/(name+'.anlogic.tmp')
        temp.write_bytes(data)
        os.replace(temp, folder/name)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    canvas = Image.new('RGB', (960, 540), '#162430')
    draw = ImageDraw.Draw(canvas)
    for i,p in enumerate(paths):
        result = Image.open(p).convert('RGB')
        if sha(p.read_bytes()) != by_name[p.name]['sha256']:
            raise AssertionError('Persisted bytes mismatch: '+p.name)
        xy = ((i%3)*320, (i//3)*270)
        canvas.paste(result.resize((320,240), Image.Resampling.LANCZOS), xy)
        draw.text((xy[0]+8,xy[1]+247), p.name+' '+str(result.size), fill='white')
    preview = folder/'preview_anlogic.png'
    canvas.save(preview)
    report = dict(created_at=now.isoformat(), target=str(folder), backup=str(backup),
                  backup_sha256=sha(backup.read_bytes()), records=records, preview=str(preview),
                  verification='All 5 persisted BMPs checked; no FPGA hardware test performed')
    (folder/'anlogic_logo_validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
