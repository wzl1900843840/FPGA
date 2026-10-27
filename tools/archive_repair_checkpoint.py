"""Create and verify an external Git snapshot + source-matched BIT archive."""
from pathlib import Path
import argparse, hashlib, io, json, subprocess, zipfile
ROOT=Path(__file__).resolve().parents[1]
sha=lambda data:hashlib.sha256(data).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--commit',required=True)
    p.add_argument('--build',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--receipt',type=Path,required=True)
    a=p.parse_args()
    if a.output.exists():raise RuntimeError('Archive already exists: '+str(a.output))
    commit=subprocess.check_output(['git','rev-parse',a.commit],cwd=ROOT,text=True).strip()
    build=ROOT/a.build
    validation=json.loads((build/'best_result/validation.json').read_text(encoding='utf-8'))
    if min(validation['timing_ns'].values())<0:raise RuntimeError('Timing gate')
    source_zip=zipfile.ZipFile(io.BytesIO(subprocess.check_output(['git','archive','--format=zip',commit],cwd=ROOT)))
    entries={n:source_zip.read(n) for n in source_zip.namelist() if not n.endswith('/')}
    for rel,digest in validation['sources'].items():
        key=rel.replace('\\','/')
        if key not in entries or sha(entries[key])!=digest:raise RuntimeError('Commit/build mismatch: '+key)
    bit=(build/'best_result/lab_ex5_i2s_v1.0.bit').read_bytes()
    if sha(bit)!=validation['bit_sha256']:raise RuntimeError('BIT mismatch')
    entries['release/lab_ex5_i2s_v1.0.bit']=bit
    entries['release/validation.json']=(build/'best_result/validation.json').read_bytes()
    manifest={'commit':commit,'hardware_tested':False,'files':{n:sha(v) for n,v in entries.items()}}
    entries['release/archive_manifest.json']=json.dumps(manifest,ensure_ascii=False,indent=2).encode('utf-8')
    a.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(a.output,'x',compression=zipfile.ZIP_DEFLATED) as z:
        for name,data in entries.items():z.writestr(name,data)
    with zipfile.ZipFile(a.output) as z:
        if z.testzip() is not None:raise RuntimeError('ZIP CRC failed')
        for name,data in entries.items():
            if sha(z.read(name))!=sha(data):raise RuntimeError('ZIP SHA failed: '+name)
    receipt={'commit':commit,'archive':str(a.output.resolve()),'sha256':sha(a.output.read_bytes()),
             'files_verified':len(entries),'bit_sha256':sha(bit),'hardware_tested':False}
    a.receipt.parent.mkdir(parents=True,exist_ok=True)
    a.receipt.write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(receipt,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
