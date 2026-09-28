"""Create a regular FAT32 .img and matched PCM extent; never access physical drives.

Default: reproducible four-image + ten-second audio demo for the shipped bitstream.
Custom: --pictures a.bmp b.bmp c.bmp d.bmp --wav music.wav
If custom audio length differs, use --configure-rtl and rebuild before programming.
"""
from pathlib import Path
import argparse, io, json, struct, hashlib, re
import numpy as np
from PIL import Image, ImageDraw
from make_audio_corpus import convert

ROOT = Path(__file__).resolve().parents[1]
SECTORS, FAT_SECTORS, DATA_LBA, AUDIO_LBA = 131072, 1024, 2080, 32768
def u16(buf, off, value): struct.pack_into('<H', buf, off, value)
def u32(buf, off, value): struct.pack_into('<I', buf, off, value)
def demo_picture(n):
    im = Image.new('RGB', (640, 480))
    yy, xx = np.indices((480, 640))
    a = np.stack(((xx+n*43)%256, (yy+n*61)%256, ((xx//80+yy//60)%2)*140+40), axis=2)
    im = Image.fromarray(a.astype('uint8'))
    d = ImageDraw.Draw(im)
    d.rectangle((140, 150, 500, 320), fill=(15, 20, 35))
    d.text((180, 200), f'PIC{n+1}   HX4S20C\n640 x 480 / RGB24\nFAT32 -> SDRAM -> HDMI', fill='white', spacing=12)
    return im
def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=ROOT/'media/demo_tf.img')
    p.add_argument('--pictures', type=Path, nargs=4)
    p.add_argument('--wav', type=Path)
    p.add_argument('--configure-rtl', action='store_true', help='Update top PCM parameters to match this image; rebuild required')
    a = p.parse_args()
    path = a.output.resolve()
    if path.suffix.lower() != '.img' or str(path).startswith('\\\\') or path.is_dir():
        raise ValueError('Output must be a regular local .img file, never a drive/device')
    pictures = []
    for n in range(4):
        im = Image.open(a.pictures[n]).convert('RGB') if a.pictures else demo_picture(n)
        if im.size not in ((640,480),(1280,960)):
            raise ValueError(f'PIC{n+1}: expected 640x480 or 1280x960, got {im.size}')
        b = io.BytesIO(); im.save(b, format='BMP'); pictures.append(b.getvalue())
    if a.wav:
        pcm = convert(a.wav)
    else:
        t = np.arange(480000)/48000
        # Continuous 440/660 Hz mixture with 20 ms attack/release, not a WAV header.
        env = np.minimum(1, np.minimum(t/.02, (10-t)/.02))
        pcm = np.rint(env*(7000*np.sin(2*np.pi*440*t)+3000*np.sin(2*np.pi*660*t))).astype('<i2').tobytes()
    pcm += bytes((-len(pcm))%512)
    audio_sectors = len(pcm)//512
    if AUDIO_LBA+audio_sectors > SECTORS:
        raise ValueError('PCM too large for this 64 MiB image')
    files=[]; cluster=3
    for n, data in enumerate(pictures):
        count=(len(data)+511)//512
        files.append((f'PIC{n+1}    BMP',cluster,data,count));cluster+=count
    audio_cluster=AUDIO_LBA-DATA_LBA+2
    if cluster>audio_cluster: raise ValueError('Pictures overlap reserved PCM extent')
    files.append(('AUDIO   PCM',audio_cluster,pcm,audio_sectors))
    fat=bytearray(FAT_SECTORS*512)
    u32(fat,0,0x0ffffff8);u32(fat,4,0xffffffff);u32(fat,8,0x0fffffff)
    directory=bytearray(512)
    for n,(name,first,data,count) in enumerate(files):
        for c in range(first,first+count): u32(fat,c*4,c+1 if c+1<first+count else 0x0fffffff)
        off=n*32;directory[off:off+11]=name.encode('ascii');directory[off+11]=0x20
        u16(directory,off+20,first>>16);u16(directory,off+26,first&65535);u32(directory,off+28,len(data))
    boot=bytearray(512);boot[0:3]=b'\xeb\x58\x90';boot[3:11]=b'MICUDEMO'
    u16(boot,11,512);boot[13]=1;u16(boot,14,32);boot[16]=2;boot[21]=0xf8
    u16(boot,24,63);u16(boot,26,255);u32(boot,32,SECTORS);u32(boot,36,FAT_SECTORS)
    u32(boot,44,2);u16(boot,48,1);u16(boot,50,6);boot[64]=0x80;boot[66]=0x29
    u32(boot,67,0x4d494355);boot[71:82]=b'MICU MEDIA ';boot[82:90]=b'FAT32   ';boot[510:]=b'\x55\xaa'
    info=bytearray(512);u32(info,0,0x41615252);u32(info,484,0x61417272)
    u32(info,488,0xffffffff);u32(info,492,0xffffffff);u32(info,508,0xaa550000)
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('wb') as f:
        f.truncate(SECTORS*512)
        for lba,data in [(0,boot),(1,info),(6,boot),(7,info),(32,fat),(32+FAT_SECTORS,fat),(DATA_LBA,directory)]:
            f.seek(lba*512);f.write(data)
        for name,first,data,count in files:
            f.seek((DATA_LBA+first-2)*512);f.write(data)
            (path.parent/(name[:8].strip()+'.'+name[8:])).write_bytes(data)
    top=ROOT/'src/user_source/hdl_source/top_tf_hdmi_audio.v'
    if a.configure_rtl:
        text=top.read_text(encoding='utf-8')
        for key,value in [('PCM_START_LBA',AUDIO_LBA),('PCM_TOTAL_SECTORS',audio_sectors)]:
            text,n=re.subn(r'(parameter \[31:0\] '+key+r'=)\d+',lambda m:m[1]+str(value),text)
            if n!=1: raise ValueError('Cannot locate top parameter '+key)
        top.write_text(text,encoding='utf-8')
        sdc=ROOT/'src/user_source/constraints_source/timing.sdc'
        from pcm_constraints import configure_text
        sdc.write_text(configure_text(sdc.read_text(encoding='utf-8'),True),encoding='utf-8')
    # Re-read stored FAT and bytes, checking all file chains/extent, not just metadata.
    with path.open('rb') as f:
        for name,first,data,count in files:
            for c in range(first,first+count):
                f.seek(32*512+c*4)
                assert struct.unpack('<I',f.read(4))[0]==(c+1 if c+1<first+count else 0x0fffffff)
            f.seek((DATA_LBA+first-2)*512);assert f.read(len(data))==data
    report={'image':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'pcm_start_lba':AUDIO_LBA,'pcm_total_sectors':audio_sectors,'pcm_seconds':len(pcm)/96000,
            'rtl_configured':a.configure_rtl,'files':[dict(name=n,first_cluster=c,bytes=len(d),sectors=s) for n,c,d,s in files]}
    path.with_suffix('.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
if __name__=='__main__': main()
