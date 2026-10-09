"""Verify production boot mute, HDMI PCM, actual BMP decoding and render the real OSD RTL."""
from pathlib import Path
import subprocess, json, time, math, hashlib
from PIL import Image, ImageDraw

ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'src/user_source/rtl'
PACK=ROOT/'media/photo_pack_anlogic'
OUT=ROOT/'tests/results/photo_ui'
OUT.mkdir(parents=True,exist_ok=True)
IV='D:/iverilog/bin/iverilog.exe'
VVP='D:/iverilog/bin/vvp.exe'
results=[]


def compile_tb(name, modules):
    target=OUT/(name+'.vvp')
    cmd=[IV,'-g2012','-s','tb_'+name,'-o',str(target),str(ROOT/'tests'/('tb_'+name+'.v'))]
    cmd += [str(p) for p in modules]
    p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True)
    (OUT/(name+'_compile.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    return target


def run(name, binary, args=(), timeout=300):
    print('Running '+name,flush=True)
    t=time.time();p=subprocess.run([VVP,str(binary),*map(str,args)],cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    log=p.stdout+p.stderr;(OUT/(name+'.log')).write_text(log,encoding='utf-8')
    ok=p.returncode==0 and 'PASS ' in log and 'FATAL' not in log
    results.append(dict(test=name,passed=ok,seconds=round(time.time()-t,2)))
    print(log.strip(),flush=True)
    if not ok:raise RuntimeError('See '+str(OUT/(name+'.log')))


boot=compile_tb('boot_mute',[ROOT/'tests/spi_flash_model.v']+[RTL/(m+'.v') for m in
    ['player_config_persistence','param_menu_controller','frame_config_cdc','w25q64_preflight_reader',
     'config_flash_journal','config_journal','w25q64_record_store','spi_byte_engine']])
run('boot_mute',boot)
audio=compile_tb('audio_mute',[p for p in RTL.glob('*.v') if p.name not in ['sys_pll_promax_40.v','global_def_125.v']])
run('audio_mute',audio)
ui=compile_tb('photo_ui',[RTL/'promax_text_overlay.v',RTL/'promax_audio_waveform.v'])
decoder=compile_tb('photo_decode',[RTL/'bmp24_decoder.v'])
(OUT/'samples.hex').write_text('\n'.join(f'{int(10500*math.sin(i*0.49)+2500*math.sin(i*1.31)) & 65535:04x}' for i in range(64)))
sheet=Image.new('RGB',(1280,1008),'#162430');draw=ImageDraw.Draw(sheet)
for n in range(1,5):
    f=PACK/f'PIC{n}.BMP';im=Image.open(f).convert('RGB');hexfile=OUT/f'PIC{n}_pixels.hex'
    pixels=im.get_flattened_data() if hasattr(im,'get_flattened_data') else im.getdata()
    hexfile.write_text('\n'.join(f'{r:02x}{g:02x}{b:02x}' for r,g,b in pixels))
    bytefile=OUT/f'PIC{n}_bytes.hex';bytefile.write_text('\n'.join(f'{b:02x}' for b in f.read_bytes()))
    run(f'decode_pic{n}',decoder,['+BMP='+str(bytefile),'+PIXELS='+str(hexfile)])
    ppm=OUT/f'PIC{n}_ui.ppm'
    run(f'ui_pic{n}',ui,['+BACKGROUND='+str(hexfile),'+SAMPLES='+str(OUT/'samples.hex'),'+OUTPUT='+str(ppm),f'+INDEX={n-1}','+NO_SUBTITLE'])
    png=PACK/f'PIC{n}_ui.png';Image.open(ppm).save(png)
    sheet.paste(Image.open(png),(((n-1)%2)*640,((n-1)//2)*504))
    draw.text((((n-1)%2)*640+12,((n-1)//2)*504+485),f'PIC{n} - RTL / demo PCM / volume 64',fill='#eef6fa')
sheet.save(PACK/'ui_preview.png')
ppm=OUT/'startup_muted.ppm'
run('ui_startup_muted',ui,['+BACKGROUND='+str(OUT/'PIC1_pixels.hex'),'+SAMPLES='+str(OUT/'samples.hex'),'+OUTPUT='+str(ppm),'+MUTED','+NO_SUBTITLE'])
Image.open(ppm).save(PACK/'startup_muted.png')
run('ui_chinese_optional',ui,['+BACKGROUND='+str(OUT/'PIC1_pixels.hex'),'+SAMPLES='+str(OUT/'samples.hex'),'+OUTPUT='+str(OUT/'optional_chinese_glyphs.ppm')])
sources={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (ROOT/'src/user_source').rglob('*.v')}
report=dict(results=results,sources=sources,scope='Real RTL with simulated clocks, real photo bytes and synthetic PCM; hardware not exercised',
            rendered=dict(resolution=[640,480],volume=64,period_ms=5000,mode='AUTO',startup_volume=0,subtitle='disabled; optional neutral Chinese glyphs tested separately'),
            files={f'PIC{n}.BMP':hashlib.sha256((PACK/f'PIC{n}.BMP').read_bytes()).hexdigest() for n in range(1,5)})
(OUT/'summary.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
(PACK/'validation.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('PASS photo UI and mute checks',flush=True)
