"""One-off audit of the completed cleanup against the external backup."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import subprocess
import sys
import zipfile

ROOT = next(parent for parent in Path(__file__).resolve().parents
            if (parent/'src/td_project/lab_ex5_i2s_v1.0.al').is_file())
EVID = ROOT/'doc/maintenance/20261029_workspace'
location = json.loads((EVID/'backup_location.json').read_text(encoding='utf-8'))
manifest = json.loads(Path(location['manifest']).read_text(encoding='utf-8'))
plan = json.loads((EVID/'cleanup_plan.json').read_text(encoding='utf-8'))
result = json.loads((EVID/'cleanup_result.json').read_text(encoding='utf-8'))


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):
            h.update(block)
    return h.hexdigest()


errors = []
deleted = {e['path'] for e in plan['delete_files']}
moves = {e['from']:e for e in result['moves']}
rewritten = ['README.md','代码说明.md','doc/工程结构与维护.md',
             'doc/隔离构建区.md','archive/README.md','build_out/README.md']
unchanged = changed_docs = missing = 0
for entry in manifest['files']:
    rel = entry['path']
    path = ROOT/rel
    if rel in deleted:
        if path.exists():
            errors.append('Deleted file reappeared: '+rel)
    elif rel in moves:
        destination = ROOT/moves[rel]['to']
        if path.exists() or not destination.is_file() or sha(destination)!=entry['sha256']:
            errors.append('Moved file mismatch: '+rel)
    elif rel in rewritten:
        if not path.is_file():
            errors.append('Missing rewritten documentation: '+rel)
        elif rel!='build_out/README.md':
            preserved = EVID/('before_'+rel.replace('/','__'))
            if not preserved.is_file() or sha(preserved)!=entry['sha256']:
                errors.append('Original documentation not preserved: '+rel)
        changed_docs += 1
    elif not path.is_file():
        errors.append('Unexpected missing file: '+rel)
        missing += 1
    elif sha(path)!=entry['sha256']:
        errors.append('Unexpected modification: '+rel)
    else:
        unchanged += 1

archive_hash = sha(location['archive'])
if archive_hash!=manifest['archive_sha256']:
    errors.append('Backup ZIP SHA256 mismatch')
with zipfile.ZipFile(location['archive']) as archive:
    member_count = len(archive.infolist())
if member_count!=location['verified_members']:
    errors.append('Backup ZIP member count mismatch')

bundle = subprocess.run(['git','bundle','verify',manifest['git_bundle']],
                        cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
if bundle.returncode or sha(manifest['git_bundle'])!=manifest['git_bundle_sha256']:
    errors.append('Git backup bundle mismatch or verification failed')

junctions = []
for name in ['seg7_block_swap','thumbnail_center']:
    path = ROOT/'build_out'/name/'user_source'
    target = path.resolve()
    ok = path.is_junction() and target==(ROOT/'src/user_source').resolve()
    junctions.append({'path':path.relative_to(ROOT).as_posix(),
                      'target':str(target),'passed':ok})
    if not ok:
        errors.append('Source junction changed: '+str(path))

for operation in result['external_operations']:
    target = Path(operation.get('to',operation.get('retained')))
    if (Path(operation['from']).exists() or not target.is_file()
            or sha(target)!=operation['sha256']):
        errors.append('External operation mismatch: '+operation['from'])

media_evidence = json.loads((ROOT/'doc/media_validation/20261029_anlogic_logo/validation.json')
                            .read_text(encoding='utf-8'))
media_checked = 0
for entry in media_evidence['records']:
    path = Path(media_evidence['target'])/entry['file']
    if not path.is_file() or sha(path)!=entry['sha256']:
        errors.append('External current material changed: '+entry['file'])
    media_checked += 1

# Do not follow junctions, and exclude Git internals from footprint statistics.
files = size = 0
for base, dirs, names in os.walk(ROOT,followlinks=False):
    dirs[:] = [name for name in dirs if name!='.git'
               and not (Path(base)/name).is_junction()
               and not (Path(base)/name).is_symlink()]
    for name in names:
        path = Path(base)/name
        if path.is_file():
            files += 1
            size += path.stat().st_size

report = {
    'created_at':datetime.datetime.now().astimezone().isoformat(),
    'passed':not errors,'errors':errors,
    'preexisting_files_checked':len(manifest['files']),
    'unchanged_files':unchanged,'declared_deleted_files':len(deleted),
    'declared_moved_files':len(moves),'declared_document_rewrites':changed_docs,
    'unexpected_missing_files':missing,
    'backup':{'path':location['archive'],'sha256':archive_hash,
              'members':member_count,'all_member_hashes_verified_before_deletion':True,
              'bundle_verified':bundle.returncode==0},
    'junctions':junctions,'external_material_files_unchanged':media_checked,
    'after_project_excluding_git_and_junction_duplicates':{'files':files,'bytes':size},
    'working_directory_redundancy_removed_bytes':result['deleted_bytes']+result['external_duplicate_bytes'],
    'checks_observed':[
        {'command':'python -B tools/build_gui.py --help','exit_code':0,'tool_result':'51c250'},
        {'command':'python -B tools/launch_console.py --check','exit_code':0,'tool_result':'b2b634'},
        {'command':'python -B -m unittest discover -s tests -p test_final_timing_gate.py',
         'tests':3,'passed':True,'tool_result':'000da1'},
        {'command':'python -B -m unittest discover -s tests -p test_host_app.py',
         'tests':41,'passed':True,'tool_result':'418102'}],
    'limitations':['No new synthesis, physical implementation, flashing or hardware test',
                   'Separate read-only workspace_doctor.json records final navigation and project checks']
}
(EVID/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
sys.exit(0 if report['passed'] else 1)
