"""Archive the repair starting point, including ignored media/release artifacts."""
from pathlib import Path
import datetime
import hashlib
import json
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    out = ROOT.parent / 'backups'
    out.mkdir(exist_ok=True)
    base = out / ('lab_ex4_tf_repair_' + stamp)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    status = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
    tag = 'backup/repair-start-' + stamp
    subprocess.run(['git', 'tag', tag, commit], cwd=ROOT, check=True)
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    files = {ROOT / name for name in names if name and (ROOT / name).is_file()}
    for relative in ('src/user_source', 'release', 'media',
                     'src/td_project/lab_ex5_i2s_v1.0_Runs/best_result'):
        directory = ROOT / relative
        if directory.is_dir():
            files.update(p for p in directory.rglob('*') if p.is_file())
    for name in ('final_timing.rpt', 'lab_ex5_i2s_v1.0_pr.timing',
                 'lab_ex5_i2s_v1.0_phy.area', 'lab_ex5_i2s_v1.0_exception.timing'):
        path = ROOT / 'build_out/rescue_cdc_20261028/td_project/lab_ex5_i2s_v1.0_Runs/phy_1' / name
        if path.is_file():
            files.add(path)
    manifest = dict(commit=commit, tag=tag, worktree_status=status, files={})
    archive = base.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(files):
            data = path.read_bytes()
            name = path.relative_to(ROOT).as_posix()
            manifest['files'][name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            z.writestr(name, data)
        z.writestr('REPAIR_BASELINE_MANIFEST.json', json.dumps(manifest, ensure_ascii=False, indent=2))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        for name, expected in manifest['files'].items():
            assert hashlib.sha256(z.read(name)).hexdigest() == expected['sha256'], name
    bundle = base.with_suffix('.bundle')
    subprocess.run(['git', 'bundle', 'create', str(bundle), '--all'], cwd=ROOT, check=True)
    subprocess.run(['git', 'bundle', 'verify', str(bundle)], cwd=ROOT, check=True)
    result = dict(commit=commit, tag=tag, archive=str(archive),
                  archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                  bundle=str(bundle), bundle_sha256=hashlib.sha256(bundle.read_bytes()).hexdigest(),
                  file_count=len(files), member_hashes_verified=True)
    base.with_suffix('.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
