"""Check waveform mapped BRAM geometry with the licensed Anlogic model.

Focused primitive test only; not a complete post-route or board simulation.
"""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build_out/resource_vendor_bram'
OUT.mkdir(parents=True, exist_ok=True)
LIB = OUT / 'work'
MS = Path('E:/altera/14.1/modelsim_ase/win32aloem')
TD = Path('E:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/sim_release/eg4')
if not LIB.exists():
    subprocess.run([str(MS/'vlib.exe'), str(LIB)], check=True, capture_output=True)
result = subprocess.run([str(MS/'vlog.exe'), '-sv', '-work', str(LIB),
    str(TD/'eg_phy_glbl.v'), str(TD/'eg_phy_bram.v'),
    str(ROOT/'tests/tb_resource_bram.v')], capture_output=True, text=True)
(OUT/'compile.log').write_text(result.stdout+result.stderr, encoding='utf-8')
result.check_returncode()
result = subprocess.run([str(MS/'vsim.exe'), '-c', '-onfinish', 'exit',
    '-lib', str(LIB), 'tb_resource_bram', 'glbl', '-l', str(OUT/'transcript.log'),
    '-do', 'run -all; quit -f'], cwd=OUT, capture_output=True, text=True, timeout=60)
log = result.stdout+result.stderr
(OUT/'console.log').write_text(log, encoding='utf-8')
passed = (result.returncode == 0 and 'PASS vendor resource BRAM:' in log
          and not any(token in log for token in ('** Fatal:', '** Error:', 'FAIL')))
(OUT/'summary.json').write_text(json.dumps({'passed': passed,
    'scope': 'Mapped waveform DP8K geometry and synchronous read; not full netlist or hardware.'},
    indent=2), encoding='utf-8')
print(log)
if not passed:
    raise SystemExit(1)
