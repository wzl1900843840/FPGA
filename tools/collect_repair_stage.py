"""Preserve a verified isolated build with source-matched simulation evidence."""
from pathlib import Path
import argparse,hashlib,json,shutil
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--stage',required=True);p.add_argument('--build',type=Path,required=True)
 p.add_argument('--extra',action='append',default=[])
 a=p.parse_args();build=(ROOT/a.build).resolve();v=json.loads((build/'best_result/validation.json').read_text(encoding='utf-8'))
 for rel,h in v['sources'].items():
  if sha(ROOT/rel)!=h:raise RuntimeError('Source differs from physical build: '+rel)
 if min(v['timing_ns'].values())<0:raise RuntimeError('Timing gate failed')
 bit=build/'best_result/lab_ex5_i2s_v1.0.bit'
 if sha(bit)!=v['bit_sha256']:raise RuntimeError('BIT hash differs')
 summary=ROOT/'tests/results/summary.json';tests=json.loads(summary.read_text())
 if not all(t['passed'] for t in tests):raise RuntimeError('RTL regression failed')
 dest=ROOT/'doc/修复验证'/a.stage;dest.mkdir(parents=True,exist_ok=True)
 paths=[summary,build/'best_result/validation.json']
 paths += [build/'best_result'/n for n in ('lab_ex5_i2s_v1.0_pr.timing','lab_ex5_i2s_v1.0_phy.area','timing_checks.rpt','hold_repair.log')]
 paths += [ROOT/'tests/results'/(t['test']+'.log') for t in tests]
 paths += [ROOT/x for x in a.extra]
 copied={}
 for src in paths:
  if not src.is_file():raise FileNotFoundError(src)
  name=src.name if src.name not in copied else src.parent.name+'_'+src.name
  target=dest/name
  if name in copied:raise RuntimeError('Duplicate evidence filename '+name)
  shutil.copy2(src,target);copied[name]=sha(target)
 record={'stage':a.stage,'build':str(build),'timing_ns':v['timing_ns'],'bit_sha256':v['bit_sha256'],
         'rtl_tests':len(tests),'evidence_sha256':copied,'hardware_tested':False,
         'test_sources':{str(f.relative_to(ROOT)):sha(f) for f in (ROOT/'tests').glob('tb_*.v')}}
 (dest/'checkpoint.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps({k:v for k,v in record.items() if k not in ('evidence_sha256','test_sources')},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
