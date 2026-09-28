"""Run TD's existing GUI flow and publish to its best_result directory after checks."""
from pathlib import Path
import subprocess,hashlib,json,shutil,re,datetime,sys
from build import reviewed_warning
ROOT=Path(__file__).resolve().parents[1]
PROJECT=ROOT/'src/td_project'
RUNS=PROJECT/'lab_ex5_i2s_v1.0_Runs'
TD=Path('E:/Anlogic/TD_6.2.1_Engineer_6.2.168.116')
name='lab_ex5_i2s_v1.0'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
files=[p for p in (ROOT/'src/user_source').rglob('*') if p.suffix in ('.v','.vh','.sdc','.adc')]
files += [PROJECT/(name+'.al'),RUNS/'syn_1/settings.cfg',RUNS/'phy_1/settings.cfg']
hashes={str(p.relative_to(ROOT)):digest(p) for p in files}
warnings=[]
for stage in (('phy_1',) if '--physical-only' in sys.argv else ('syn_1','phy_1')):
 print('Running existing GUI flow: '+stage,flush=True)
 path=RUNS/stage
 with (path/'diagnostic_build.log').open('w',encoding='utf-8') as f:
  result=subprocess.run([str(TD/'bin/td_commands_prompt.exe'),(TD/'doc/scripts/DefaultFlow.tcl').as_posix()],cwd=path,stdout=f,stderr=subprocess.STDOUT)
 log=(path/'diagnostic_build.log').read_text(encoding='utf-8',errors='replace')
 if result.returncode or re.search(r'\b(?:ERROR|FATAL)\s*:',log):raise RuntimeError('Build failed: '+stage)
 critical=[line for line in log.splitlines() if 'CRITICAL-WARNING' in line and not reviewed_warning(line,log)]
 if critical:raise RuntimeError('Unreviewed critical warnings: '+str(critical))
 warnings += [line for line in log.splitlines() if 'WARNING' in line]
 if 'HDL-1201' not in log and stage=='syn_1' and 'export_db' not in log:raise RuntimeError('Missing synthesis completion')
for f,h in hashes.items():
 if digest(ROOT/f)!=h:raise RuntimeError('Source changed during build: '+f)
phy=RUNS/'phy_1'
timing=(phy/(name+'_pr.timing')).read_text(errors='replace')
values={k:float(re.search(k+r':\s*(-?[\d.]+)ns',timing)[1]) for k in ('SWNS','STNS','HWNS','HTNS')}
if min(values.values())<0:raise RuntimeError('Timing failed: '+str(values))
bit=phy/(name+'.bit')
if bit.stat().st_mtime<max(p.stat().st_mtime for p in files):raise RuntimeError('Stale bit')
best=RUNS/'best_result';best.mkdir(exist_ok=True)
backup=ROOT/'tests/results/before_local_diagnostic';backup.mkdir(exist_ok=True)
old=best/bit.name
if old.exists() and not (backup/bit.name).exists():shutil.copy2(old,backup/bit.name)
for filename in (bit.name,name+'_phy.ts',name+'_inst.bid'):
 shutil.copy2(phy/filename,best/filename)
report={'built_at':datetime.datetime.now().isoformat(),'bit_sha256':digest(bit),'timing_ns':values,'sources':hashes,'hardware_tested':False,'warnings':warnings,
 'purpose':'K4 held with SW4 high at reset: SW3 low = local pixels, SW3 high = synthetic stream through read FIFO; normal reset restores player'}
(best/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k!='sources'},ensure_ascii=False,indent=2),flush=True)

