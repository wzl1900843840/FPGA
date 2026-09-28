from pathlib import Path
import subprocess,time,sys
root=Path(__file__).resolve().parents[1];out=root/'tests/results';out.mkdir(exist_ok=True)
files=[p for p in (root/'src/user_source/rtl').glob('*.v') if p.name not in ['sys_pll_promax_40.v','global_def_125.v']]
files.append(root/'tests/lut1_model.v')
binary=out/'chain.vvp'
c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_chain','-o',str(binary),str(root/'tests/tb_chain.v')]+[str(p) for p in files],capture_output=True,text=True)
(out/'chain_compile.log').write_text(c.stdout+c.stderr,encoding='utf-8');print(c.stdout+c.stderr,flush=True)
if c.returncode:raise SystemExit(c.returncode)
with (out/'chain.log').open('w') as log:
 c=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)]+(['+VIDEO_ONLY'] if '--video-only' in sys.argv else []),stdout=log,stderr=subprocess.STDOUT,timeout=1800)
print((out/'chain.log').read_text(),flush=True)
raise SystemExit(c.returncode)
