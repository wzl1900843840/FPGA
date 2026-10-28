"""Sweep frame requests triggered after each of 128 authorized command positions.

The frame pulse is generated on the next pixel edge, then crosses the existing
request synchronizer. This does not claim exhaustive physical CDC verification.
"""
from pathlib import Path
import json,subprocess
root=Path(__file__).resolve().parents[1]
out=root/'tests/results/burst_boundaries';out.mkdir(parents=True,exist_ok=True)
rtl=root/'src/user_source/rtl';binary=out/'sweep.vvp'
modules=('media_frame_reader','media_sdram_arbiter','frame_config_cdc','fifo_prefetch_2','afifo_32_16_256')
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_fix_burst_abort','-o',str(binary),
    str(root/'tests/tb_fix_burst_abort.v')]+[str(rtl/(m+'.v')) for m in modules],check=True)
results=[]
with (out/'sweep.log').open('w',encoding='utf-8') as log:
    for command in range(1,129):
        p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary),f'+TRIGGER={command}'],
            capture_output=True,text=True,timeout=30)
        text=p.stdout+p.stderr;log.write(f'TRIGGER={command}\n'+text)
        ok=p.returncode==0 and 'PASS frame-overrun' in text
        results.append(dict(trigger_command=command,passed=ok))
        if not ok:raise RuntimeError(f'command {command}: {text}')
(out/'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
print('PASS burst boundaries: 128/128 authorized command positions, owner drained and next frame complete')
