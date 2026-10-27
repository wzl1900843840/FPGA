from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[1];rtl=r/'src/user_source/rtl';out=r/'tests/results/alarm_audio.vvp'
files=[p for p in rtl.glob('*.v') if p.name not in ('sys_pll_promax_40.v','global_def_125.v')]
for name,expected in [('alarm_audio','PASS alarm audio:'),('alarm_hdmi','PASS alarm HDMI:')]:
 out=r/f'tests/results/{name}.vvp'
 subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_'+name,'-o',str(out),str(r/f'tests/tb_{name}.v')]+list(map(str,files)),check=True)
 p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out)],capture_output=True,text=True,timeout=90)
 log=p.stdout+p.stderr;(r/f'tests/results/{name}.log').write_text(log,encoding='utf-8');print(log);p.check_returncode()
 if expected not in log:raise RuntimeError('No PASS')
