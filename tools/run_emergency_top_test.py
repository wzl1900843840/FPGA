"""Production top control integration; only board boundary devices are models."""
from pathlib import Path
import subprocess,sys
import argparse
r=Path(__file__).resolve().parents[1]
argparser=argparse.ArgumentParser()
argparser.add_argument('--boot-metrics',action='store_true')
argparser.add_argument('--bench',choices=('emergency_top','boot_watchdogs'),default='emergency_top')
argparser.add_argument('--out',type=Path,default=r/'tests/results')
args=argparser.parse_args()
rtl=r/'src/user_source/rtl';args.out.mkdir(parents=True,exist_ok=True)
stem='boot_metrics_top' if args.boot_metrics else args.bench
out=args.out/(stem+'.vvp')
files=[p for p in rtl.glob('*.v') if p.name!='sys_pll_promax_40.v']
files += [r/'src/user_source/hdl_source'/n for n in ('top_tf_hdmi_audio.v','lane_lvds_10_1.v','hdmi_phy_warpper.v')]
milestones=args.boot_metrics
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012',*(['-DBOOT_METRICS_TEST'] if milestones else []),'-s','tb_'+args.bench,'-o',str(out),str(r/('tests/tb_'+args.bench+'.v')),str(r/'tests/tb_local_pattern.v'),str(r/'tests/lut1_model.v')]+list(map(str,files)),check=True)
p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out)],capture_output=True,text=True,timeout=60)
log=p.stdout+p.stderr;(args.out/(stem+'.log')).write_text(log,encoding='utf-8')
print(log);p.check_returncode()
expected='PASS boot milestones:' if milestones else ('PASS boot watchdogs:' if args.bench=='boot_watchdogs' else 'PASS emergency top:')
if expected not in log:raise RuntimeError('Missing PASS')
