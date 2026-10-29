from pathlib import Path
import json,hashlib,os,shutil,datetime,subprocess
ROOT=Path('D:/FPGA/anlu/example_code111/lab_ex4_tf').resolve()
WORK=ROOT/'build_out/workspace_cleanup_20261029'
location=json.loads((WORK/'backup_location.json').read_text(encoding='utf-8'))
backup=json.loads(Path(location['manifest']).read_text(encoding='utf-8'))
records={e['path']:e for e in backup['files']}
KEEP={'workspace_cleanup_20261029','alert_layout_20261029','gui_verified_20261029','gui_20261029_145246',
      'resource_R2E_20261029','fullchain_I_20261029','rescue_cdc_20261028',
      'repair_stage6_final_20261028','seg7_block_swap','thumbnail_center','maintenance_logs'}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
 return h.hexdigest()
active=subprocess.run(['powershell','-NoProfile','-Command',
 'Get-Process td_commands_prompt,iverilog,vvp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id'],text=True,capture_output=True).stdout.strip()
if active:raise RuntimeError('Build or simulation running: '+active)
candidates=[]
for rel,entry in records.items():
 parts=Path(rel).parts; p=ROOT/rel
 generated_build=parts[0]=='build_out' and len(parts)>1 and parts[1] not in KEEP and rel!='build_out/README.md'
 generated_test=rel.startswith('tests/results/') and not rel.startswith('tests/results/hardware_pass_20260928/') and (p.suffix.lower() in {'.vvp','.hex','.ppm','.qdb','.qpg','.qtl'} or '/work/' in rel)
 bytecode=p.suffix=='.pyc' and '__pycache__' in parts
 if generated_build or generated_test or bytecode:
  if not p.is_file():raise RuntimeError('File disappeared: '+rel)
  if sha(p)!=entry['sha256']:raise RuntimeError('File changed since backup: '+rel)
  candidates.append(entry)
protected=[]
deleted_names={e['path'] for e in candidates}
for rel,e in records.items():
 if rel.startswith(('src/','tools/','tests/','media/','config/','.workbuddy/','.spec-workflow/','doc/','docs/')) and rel not in deleted_names:
  protected.append(e)
plan={'root':str(ROOT),'backup':location,'keep_build_directories':sorted(KEEP),'delete_files':candidates,'protected_files':protected}
(WORK/'cleanup_plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
print('CLEANUP',len(candidates),'files',sum(e['bytes'] for e in candidates),'bytes',flush=True)
for e in candidates:
 p=ROOT/e['path']; resolved=p.resolve()
 if not resolved.is_relative_to(ROOT) or p.is_symlink():raise RuntimeError('Unsafe path '+str(p))
 p.unlink()
for start in [ROOT/'build_out',ROOT/'tests/results',ROOT/'tools']:
 for base,dirs,files in os.walk(start,topdown=False,followlinks=False):
  p=Path(base)
  if p==start or p==WORK or p.is_symlink() or p.is_junction():continue
  try:p.rmdir()
  except OSError:pass
moves=[]
dest=ROOT/'archive/maintenance/legacy_netlist';dest.mkdir(parents=True,exist_ok=True)
for name in ['tb_fade.log','tb_fade.ys']:
 src=ROOT/'netlist'/name; target=dest/name
 if target.exists():raise RuntimeError('Move target exists')
 digest=sha(src);shutil.move(src,target);assert sha(target)==digest
 moves.append({'from':src.relative_to(ROOT).as_posix(),'to':target.relative_to(ROOT).as_posix(),'sha256':digest})
for dirname in ['netlist','icarus']:
 p=ROOT/dirname
 if p.exists():
  try:p.rmdir()
  except OSError:pass
external=[]
for name in ['lab_ex4_tf.zip','lab_ex4_tf (2).zip']:
 src=ROOT.parent/name
 if src.is_file():
  target=ROOT.parent/'backups/imported'/name;target.parent.mkdir(exist_ok=True)
  if target.exists():raise RuntimeError('External archive destination exists')
  digest=sha(src);shutil.move(src,target);assert sha(target)==digest
  external.append({'operation':'move','from':str(src),'to':str(target),'sha256':digest})
duplicate=ROOT.parent/'lab_ex5_i2s/演示视频/VID_20260428_143508.mp4'
retained=ROOT/'archive/reference/演示视频/VID_20260428_143508.mp4'
duplicate_bytes=0
if duplicate.is_file() and retained.is_file():
 digest=sha(duplicate)
 if digest==sha(retained):
  backed=records[retained.relative_to(ROOT).as_posix()];assert backed['sha256']==digest
  duplicate_bytes=duplicate.stat().st_size
  external.append({'operation':'delete_exact_duplicate','from':str(duplicate),'retained':str(retained),'sha256':digest,'bytes':duplicate_bytes})
  duplicate.unlink()
  try:duplicate.parent.rmdir()
  except OSError:pass
report={'created_at':datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        'backup':location,'deleted_files':len(candidates),'deleted_bytes':sum(e['bytes'] for e in candidates),
        'external_duplicate_bytes':duplicate_bytes,'kept_build_directories':sorted(KEEP),'moves':moves,'external_operations':external}
(WORK/'cleanup_result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
