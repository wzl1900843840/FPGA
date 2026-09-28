"""Verify local-pattern isolation using the actual production top and pixel pipeline."""
from pathlib import Path
import subprocess,sys
r=Path(__file__).resolve().parents[1]
rtl=r/'src/user_source/rtl';kind='fifo_pattern' if '--fifo' in sys.argv else 'local_pattern'
out=r/('tests/results/'+kind+'.vvp')
files=[p for p in rtl.glob('*.v') if p.name!='sys_pll_promax_40.v']
files += [r/'src/user_source/hdl_source'/n for n in ('top_tf_hdmi_audio.v','lane_lvds_10_1.v','hdmi_phy_warpper.v')]
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012',*(['-DFIFO_DIAG'] if kind=='fifo_pattern' else []),'-s','tb_local_pattern','-o',str(out),str(r/'tests/tb_local_pattern.v'),str(r/'tests/lut1_model.v')]+list(map(str,files)),check=True)
with (r/('tests/results/'+kind+'.log')).open('w') as f:
 result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out)],stdout=f,stderr=subprocess.STDOUT,timeout=600)
log=(r/('tests/results/'+kind+'.log')).read_text()
print(log);result.check_returncode()
if 'PASS local_pattern:' not in log:raise RuntimeError('No PASS result')
