"""One-time full backup for the user-authorized 2026-10-30 workspace cleanup."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT.parent / 'backups' / 'workspace_cleanup_20261030'
assert ROOT.name == 'lab_ex4_tf' and OUT.parent.name == 'backups'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    archive = OUT / 'project_before.zip'
    if archive.exists():
        raise SystemExit('Refuse to overwrite existing backup')
    omissions, links, files = [], [], []

    def walk(directory):
        try:
            with os.scandir(directory) as it:
                entries = sorted(it, key=lambda e: e.name)
        except OSError as exc:
            omissions.append({'path': str(directory.relative_to(ROOT)), 'error': str(exc)})
            return
        for entry in entries:
            path = Path(entry.path)
            if entry.name == '.git':
                continue
            if entry.is_symlink() or entry.is_junction():
                links.append({'path': path.relative_to(ROOT).as_posix(), 'target': os.readlink(path)})
            elif entry.is_dir(follow_symlinks=False):
                yield from walk(path)
            elif entry.is_file(follow_symlinks=False):
                yield path

    started = time.time()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as z:
        for i, path in enumerate(walk(ROOT), 1):
            data = path.read_bytes()
            relative = path.relative_to(ROOT).as_posix()
            z.writestr(relative, data)
            files.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            if i % 2000 == 0:
                print('backed up', i, 'files', round(time.time() - started, 1), 's', flush=True)
    (OUT / 'backup_manifest.json').write_text(json.dumps({
        'root': str(ROOT), 'files': files, 'junctions': links, 'omissions': omissions,
    }, ensure_ascii=False, indent=2), encoding='utf-8')
    with zipfile.ZipFile(archive) as z:
        for i, entry in enumerate(files, 1):
            if hashlib.sha256(z.read(entry['path'])).hexdigest() != entry['sha256']:
                raise SystemExit('Backup verification failed: ' + entry['path'])
            if i % 2000 == 0:
                print('verified', i, 'files', flush=True)
    for args, name in [(['status', '--short'], 'git_status_before.txt'), (['diff', '--binary'], 'git_diff_before.patch')]:
        result = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, check=True)
        (OUT / name).write_bytes(result.stdout)
    bundle = subprocess.run(['git', 'bundle', 'create', str(OUT / 'git_before.bundle'), '--all'], cwd=ROOT, capture_output=True)
    verify = subprocess.run(['git', 'bundle', 'verify', str(OUT / 'git_before.bundle')], cwd=ROOT, capture_output=True) if bundle.returncode == 0 else bundle
    (OUT / 'git_bundle_verify.txt').write_bytes(bundle.stdout + bundle.stderr + verify.stdout + verify.stderr)
    assert bundle.returncode == verify.returncode == 0
    digest = hashlib.sha256()
    with archive.open('rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    report = {
        'archive': str(archive), 'archive_bytes': archive.stat().st_size,
        'archive_sha256': digest.hexdigest(), 'verified_members': len(files),
        'original_bytes': sum(e['bytes'] for e in files), 'junctions': links,
        'omissions': omissions, 'git_bundle_verified': True,
        'elapsed_seconds': round(time.time() - started, 1),
    }
    (OUT / 'backup_verified.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
