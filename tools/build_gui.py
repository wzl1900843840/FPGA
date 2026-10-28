"""Compatibility build entry: freeze sources and run the verified isolated flow.

Outputs remain under build_out; the historical src/best_result is preserved.
"""
from pathlib import Path
import argparse,datetime,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--out',type=Path)
p.add_argument('--physical-only',action='store_true')
a=p.parse_args()
if a.physical_only and a.out is None:p.error('--physical-only requires --out pointing at a prepared isolated tree')
out=(a.out or ROOT/'build_out'/('gui_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))).resolve()
if not a.physical_only:
    subprocess.run([sys.executable,str(ROOT/'tools/setup_isolated_build.py'),'--out',str(out),'--link-mode','copy'],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'tools/build_isolated.py'),'--out',str(out),'--frozen-source']+(['--physical-only'] if a.physical_only else []),cwd=ROOT,check=True)
print('Verified candidate: '+str(out/'best_result'))
