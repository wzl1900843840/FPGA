from pathlib import Path
import os, json, hashlib, zipfile, datetime, subprocess
ROOT=Path('D:/FPGA/anlu/example_code111/lab_ex4_tf').resolve()
WORK=ROOT/'build_out/workspace_cleanup_20261029'
STAMP=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y%m%d_%H%M%S')
DEST=ROOT.parent/'backups'/('workspace_cleanup_'+STAMP)
DEST.mkdir(parents=True,exist_ok=False)
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
files=[];links=[]
for base,dirs,names in os.walk(ROOT):
 keep=[]
 for d in dirs:
  p=Path(base)/d
  if p==ROOT/'.git' or p==WORK:continue
  if p.is_symlink() or p.is_junction():links.append({'path':p.relative_to(ROOT).as_posix(),'target':str(p.resolve())});continue
  keep.append(d)
 dirs[:]=keep
 for n in names:
  p=Path(base)/n
  if p.is_symlink():raise RuntimeError('Unexpected file link: '+str(p))
  files.append(p)
archive=DEST/'project_before.zip';records=[]
with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED,compresslevel=1) as z:
 for i,p in enumerate(files):
  data=p.read_bytes(); rel=p.relative_to(ROOT).as_posix(); records.append({'path':rel,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)});z.writestr(rel,data)
  if i%2000==0:print('BACKUP',i,'/',len(files),flush=True)
print('VERIFY archive members',flush=True)
with zipfile.ZipFile(archive) as z:
 for record in records:
  if hashlib.sha256(z.read(record['path'])).hexdigest()!=record['sha256']:raise RuntimeError('Backup mismatch '+record['path'])
bundle=DEST/'git_before.bundle'
subprocess.run(['git','bundle','create',str(bundle),'--all'],cwd=ROOT,check=True)
subprocess.run(['git','bundle','verify',str(bundle)],cwd=ROOT,check=True)
subprocess.run(['git','status','--porcelain=v1','-uall'],cwd=ROOT,stdout=(DEST/'git_status_before.txt').open('wb'),check=True)
(DEST/'git_diff_before.patch').write_bytes(subprocess.check_output(['git','diff','--binary'],cwd=ROOT))
report={'root':str(ROOT),'created_at':STAMP,'archive':str(archive),'archive_sha256':sha(archive),'git_bundle':str(bundle),'git_bundle_sha256':sha(bundle),'files':records,'junctions_skipped':links,'verified_members':len(records)}
(DEST/'backup_manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
(WORK/'backup_location.json').write_text(json.dumps({'directory':str(DEST),'archive':str(archive),'manifest':str(DEST/'backup_manifest.json'),'verified_members':len(records)},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'backup':str(DEST),'members':len(records),'archive_bytes':archive.stat().st_size,'sha256':report['archive_sha256']},ensure_ascii=False),flush=True)
