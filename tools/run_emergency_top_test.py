"""Production top control integration; only board boundary devices are models."""
from pathlib import Path
import subprocess,sys
r=Path(__file__).resolve().parents[1]
rtl=r/'src/user_source/rtl';out=r/'tests/results/emergency_top.vvp'
files=[p for p in rtl.glob('*.v') if p.name!='sys_pll_promax_40.v']
files += [r/'src/user_source/hdl_source'/n for n in ('top_tf_hdmi_audio.v','lane_lvds_10_1.v','hdmi_phy_warpper.v')]
milestones='--boot-metrics' in sys.argv
if milestones:out=r/'tests/results/boot_metrics_top.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012',*(['-DBOOT_METRICS_TEST'] if milestones else []),'-s','tb_emergency_top','-o',str(out),str(r/'tests/tb_emergency_top.v'),str(r/'tests/tb_local_pattern.v'),str(r/'tests/lut1_model.v')]+list(map(str,files)),check=True)
p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out)],capture_output=True,text=True,timeout=60)
log=p.stdout+p.stderr;(r/('tests/results/boot_metrics_top.log' if milestones else 'tests/results/emergency_top.log')).write_text(log,encoding='utf-8')
print(log);p.check_returncode()
if ('PASS boot milestones:' if milestones else 'PASS emergency top:') not in log:raise RuntimeError('Missing PASS')
