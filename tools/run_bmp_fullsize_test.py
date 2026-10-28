from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
out=root/'tests/results';out.mkdir(parents=True,exist_ok=True)
binary=out/'bmp_fullsize.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_bmp_fullsize','-o',str(binary),str(root/'tests/tb_bmp_fullsize.v'),str(root/'src/user_source/rtl/bmp24_decoder.v')],check=True)
with (out/'bmp_fullsize.log').open('w',encoding='utf-8') as f:
    result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=240)
log=(out/'bmp_fullsize.log').read_text(encoding='utf-8');print(log);result.check_returncode()
if 'PASS bmp_fullsize:' not in log:raise RuntimeError('Missing PASS')
