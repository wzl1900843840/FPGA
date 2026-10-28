from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[1];rtl=R/'src/user_source/rtl'
files=[p for p in rtl.glob('*.v') if p.name!='sys_pll_promax_40.v']
files+=[R/'src/user_source/hdl_source'/n for n in ('top_tf_hdmi_audio.v','lane_lvds_10_1.v','hdmi_phy_warpper.v')]
out=R/'tests/results/recovery_top.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_recovery_top','-o',str(out),str(R/'tests/tb_recovery_top.v'),str(R/'tests/tb_local_pattern.v'),str(R/'tests/lut1_model.v')]+list(map(str,files)),check=True)
with (R/'tests/results/recovery_top.log').open('w',encoding='utf-8') as f:
 p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out)],stdout=f,stderr=subprocess.STDOUT,text=True,timeout=150)
log=(R/'tests/results/recovery_top.log').read_text(encoding='utf-8');print(log);p.check_returncode()
if 'PASS recovery top:' not in log:raise RuntimeError('Missing PASS')
