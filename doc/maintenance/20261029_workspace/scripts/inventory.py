from pathlib import Path
from collections import defaultdict, Counter
import os, json, hashlib, time, subprocess
ROOT=Path('D:/FPGA/anlu/example_code111')
PROJECT=ROOT/'lab_ex4_tf'
OUT=PROJECT/'build_out/workspace_cleanup_20261029'
OUT.mkdir(parents=True,exist_ok=True)
rows=[]; groups=defaultdict(lambda:[0,0]); exts=Counter()
for directory,dirs,files in os.walk(ROOT):
    dirs[:]=[d for d in dirs if d!='.git' and not (Path(directory)/d).is_symlink() and not (Path(directory)/d).is_junction()]
    for name in files:
        p=Path(directory)/name
        try: st=p.stat()
        except OSError: continue
        rel=p.relative_to(ROOT).as_posix(); parts=rel.split('/')
        rows.append(dict(path=rel,bytes=st.st_size,mtime=st.st_mtime))
        key='/'.join(parts[:3] if parts[0]=='lab_ex4_tf' else parts[:2])
        groups[key][0]+=1;groups[key][1]+=st.st_size;exts[p.suffix.lower()]+=st.st_size
report=dict(files=rows,groups=dict(groups),total_bytes=sum(r['bytes'] for r in rows))
(OUT/'inventory_before.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'count':len(rows),'total_GiB':round(report['total_bytes']/2**30,3),'groups_largest':sorted([dict(path=k,files=v[0],MiB=round(v[1]/2**20,2)) for k,v in groups.items()],key=lambda r:-r['MiB'])[:55],'files_largest':sorted(rows,key=lambda r:-r['bytes'])[:18]},ensure_ascii=False,indent=2))
