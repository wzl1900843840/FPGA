"""Compatibility build entry: freeze sources and run the verified isolated flow.

Outputs remain under build_out; the historical src/best_result is preserved.
TD's native GUI button does not call this script. Use build_verified.cmd or
this script for the complete final hold-repair and acceptance sequence.
"""
from pathlib import Path
import argparse,datetime,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--out',type=Path)
p.add_argument('--physical-only',action='store_true')
p.add_argument('--route-effort',choices=('high','routability'))
a=p.parse_args()
if a.physical_only and a.out is None:p.error('--physical-only requires --out pointing at a prepared isolated tree')
if a.physical_only and a.route_effort:p.error('--route-effort must be set when preparing a new isolated build')
out=(a.out or ROOT/'build_out'/('gui_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))).resolve()
if not a.physical_only:
    subprocess.run([sys.executable,str(ROOT/'tools/setup_isolated_build.py'),'--out',str(out),'--link-mode','copy','--route-effort',a.route_effort or 'routability'],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'tools/build_isolated.py'),'--out',str(out),'--frozen-source']+(['--physical-only'] if a.physical_only else []),cwd=ROOT,check=True)
print('Verified candidate: '+str(out/'best_result'))
print('Final timing is in best_result/final_timing.rpt and validation.json.')
print('The native TD GUI run table belongs to its separate src/.../phy_1 run.')
