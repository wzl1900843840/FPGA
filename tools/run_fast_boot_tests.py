"""Check early publication, shared vendor SDRAM and the rendered audio panel."""
from pathlib import Path
import hashlib
import json
import subprocess
import time
import math
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'src/user_source/rtl'
OUT = ROOT / 'tests/results/fast_boot'
OUT.mkdir(parents=True, exist_ok=True)
MS = Path('E:/altera/14.1/modelsim_ase/win32aloem')
PROJECT = ROOT / 'src/td_project'
INC = ROOT / 'src/user_source/hdl_source/include'
CHIP = Path('D:/FPGA/anlu/5_软件工具及驱动/lab_ex_2025_7_12_nosoft/HX4S20C_lab_ex/lab_ex_4_tf_sdram_etnernet_pc/source_code/model/IS42s32200.v')
results = []


def simulate(name, command, expected, cwd=ROOT, timeout=300):
    print('Running ' + name, flush=True)
    start = time.time()
    proc = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    log = proc.stdout + proc.stderr
    (OUT / (name + '.log')).write_text(log, encoding='utf-8')
    ok = proc.returncode == 0 and expected in log and not any(
        s in log for s in ('ERROR:', 'FAIL', '** Fatal:', '** Error:'))
    results.append(dict(test=name, passed=ok, seconds=round(time.time()-start, 2)))
    print('\n'.join(log.splitlines()[-10:]), flush=True)
    if not ok:
        raise RuntimeError('See ' + str(OUT / (name + '.log')))


modules = ['media_ingest_frontend', 'sd_sector_replay_buffer', 'media_ingest_pipeline',
           'fat32_volume_scanner', 'fat32_file_streamer', 'bmp24_decoder',
           'media_frame_loader', 'media_sdram_write_cdc']
early = OUT / 'early.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'tb_early_ingest',
                '-o', str(early), str(ROOT/'tests/tb_early_ingest.v')] +
               [str(RTL/(m+'.v')) for m in modules], check=True)
simulate('early_valid', ['D:/iverilog/bin/vvp.exe', str(early)], 'PASS early ingest:')
simulate('early_bad_tail', ['D:/iverilog/bin/vvp.exe', str(early), '+BAD_TAIL'], 'PASS early ingest:')
simulate('early_abort_burst', ['D:/iverilog/bin/vvp.exe', str(early), '+ABORT_BURST'], 'PASS early ingest:')

sd = OUT/'sd_fast.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-DFAST_SD', '-s', 'tb_sd_protocol', '-o', str(sd),
                str(ROOT/'tests/tb_sd_protocol.v'), str(ROOT/'tests/spi_sd_model.v')] +
               [str(RTL/(m+'.v')) for m in ('sd_media_service', 'sd_spi_init', 'sd_spi_command',
                                          'sd_spi_byte_engine', 'sd_spi_sector_reader')], check=True)
simulate('sd_fast', ['D:/iverilog/bin/vvp.exe', str(sd)], 'PASS SD fast clocks:')

image = Image.open(ROOT/'media/PIC1.BMP').convert('RGB')
if image.size != (640, 480):
    raise ValueError('Preview fixture must be 640x480')
pixels = image.get_flattened_data() if hasattr(image, 'get_flattened_data') else image.getdata()
(OUT/'background.hex').write_text('\n'.join(f'{r:02x}{g:02x}{b:02x}' for r,g,b in pixels))
(OUT/'samples.hex').write_text('\n'.join(f'{int(10500*math.sin(i*0.49)+2500*math.sin(i*1.31)) & 65535:04x}' for i in range(64)))
wave = OUT/'waveform.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'tb_waveform', '-o', str(wave),
                str(ROOT/'tests/tb_waveform.v'), str(RTL/'promax_audio_waveform.v')], check=True)
simulate('waveform', ['D:/iverilog/bin/vvp.exe', str(wave),
                     '+BACKGROUND='+str(OUT/'background.hex'), '+SAMPLES='+str(OUT/'samples.hex'),
                     '+OUTPUT='+str(OUT/'waveform_preview.ppm')], 'PASS waveform:')
Image.open(OUT/'waveform_preview.ppm').save(OUT/'waveform_preview.png')

lib = OUT / 'work'
if not lib.exists():
    subprocess.run([str(MS/'vlib.exe'), str(lib)], check=True, capture_output=True)
groups = [(['-suppress', '2121', '+incdir+'+str(INC)],
           [INC/n for n in ('sdr_as_ram.enc.v', 'sdr_init_ref.enc.v', 'sdr_wrrd.enc.v')] +
           [ROOT/'src/user_source/hdl_source/SD/sdram.v', CHIP, ROOT/'tests/sdram_chip_model.v']),
          (['-sv'], [RTL/(m+'.v') for m in ('afifo_32_16_256', 'fifo_prefetch_2',
                       'frame_config_cdc', 'media_frame_reader', 'media_sdram_write_cdc', 'media_sdram_arbiter', 'thumbnail_cache_builder')] +
           [ROOT/'tests/lut1_model.v', ROOT/'tests/tb_vendor_shared.v', ROOT/'tests/tb_vendor_shared_cache.v'])]
with (OUT/'vendor_compile.log').open('w') as log:
    for flags, files in groups:
        proc = subprocess.run([str(MS/'vlog.exe'), '-work', str(lib)] + flags +
                              [str(f) for f in files], cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT)
        if proc.returncode:
            raise RuntimeError('See '+str(OUT/'vendor_compile.log'))
simulate('vendor_shared', [str(MS/'vsim.exe'), '-c', '-onfinish', 'exit', '-lib', str(lib),
                          'tb_vendor_shared', '-l', str(OUT/'vendor_shared_transcript.log'), '-do', 'run -all; quit -f'],
         'PASS vendor shared:', cwd=PROJECT)
simulate('vendor_shared_cache', [str(MS/'vsim.exe'), '-c', '-onfinish', 'exit', '-lib', str(lib),
                                'tb_vendor_shared_cache', '-l', str(OUT/'vendor_shared_cache_transcript.log'), '-do', 'run -all; quit -f'],
         'PASS vendor shared cache:', cwd=PROJECT, timeout=600)

sources = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
           for f in (ROOT/'src/user_source').rglob('*.v')}
(OUT/'summary.json').write_text(json.dumps(dict(results=results, sources=sources), indent=2))
print('PASS fast boot checks', flush=True)
