"""Plan/apply only the explicitly reviewed cleanup, with verified backup and hash guards."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import zipfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
BACKUP = ROOT.parent / 'backups/workspace_cleanup_20261030'
PLAN = HERE / 'cleanup_plan.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def safe_file(relative):
    path = ROOT / relative
    if not path.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError('Escapes workspace: ' + relative)
    for part in [path, *path.parents]:
        if part == ROOT:
            break
        if part.is_symlink() or part.is_junction():
            raise ValueError('Link in deletion path: ' + str(part))
    return path


def build_plan():
    backup = json.loads((BACKUP / 'backup_manifest.json').read_text(encoding='utf-8'))
    verified = json.loads((BACKUP / 'backup_verified.json').read_text(encoding='utf-8'))
    assert verified['verified_members'] == len(backup['files']) and verified['git_bundle_verified']
    selected = []
    roots = [f'build_out/final_repair_candidate_20261030_{n}' for n in range(1, 21)]
    outputs = {
        'build_out/demo_menu.ppm', 'build_out/demo_menu_bram.ppm',
        'build_out/tb_fat32_bpb_reuse.vvp', 'build_out/tb_fat32_opt.vvp',
        'build_out/tb_recovery_fix.vvp', 'build_out/tb_wave_blend_equiv.vvp',
        'archive/reference/演示视频/VID_20260428_143508.mp4',
        '设计参考例程文档.md',
    }
    for entry in backup['files']:
        rel = entry['path']
        if any(rel.startswith(folder + '/') for folder in roots):
            reason = 'Superseded trial 1-20; keep baseline, candidate 21 and later GUI reproduction'
        elif rel in outputs:
            reason = 'Regenerable output or archived historical reference; full original retained in verified ZIP'
        elif rel.startswith('archive/releases/') and rel.endswith('.bit'):
            reason = 'Historical pre-fix BIT; retain original manifest/log/report, restore BIT from verified ZIP'
        else:
            continue
        path = safe_file(rel)
        if not path.is_file() or digest(path) != entry['sha256']:
            raise ValueError('Changed since backup: ' + rel)
        selected.append({**entry, 'reason': reason})
    plan = {
        'root': str(ROOT), 'backup': verified, 'remove_empty_roots': roots,
        'delete_files': selected, 'file_count': len(selected),
        'bytes': sum(e['bytes'] for e in selected),
        'protected': ['src/**', 'tools/**', 'tests/**', 'config/**', 'logs/**', 'media/**',
                      'build_out/final_repair_candidate_20261030_21/**',
                      'build_out/final_repair_baseline_20261030/**',
                      'build_out/gui_blackbox_fix_20261030/**',
                      'build_out/promax_audio_waveform_old.v',
                      'build_out/promax_audio_waveform_pre_blend_refactor.v'],
    }
    PLAN.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: plan[k] for k in ('file_count', 'bytes', 'remove_empty_roots', 'protected')}, ensure_ascii=False, indent=2))


def apply_plan():
    plan = json.loads(PLAN.read_text(encoding='utf-8'))
    assert Path(plan['root']).resolve() == ROOT.resolve()
    if (HERE / 'cleanup_result.json').exists():
        raise SystemExit('Cleanup already has a result; do not replay')
    manifest = json.loads((BACKUP / 'backup_manifest.json').read_text(encoding='utf-8'))
    original = {e['path']: e for e in manifest['files']}
    # Validate every selected path and its archived bytes before the first deletion.
    with zipfile.ZipFile(plan['backup']['archive']) as archive:
        for entry in plan['delete_files']:
            path = safe_file(entry['path'])
            assert entry['sha256'] == original[entry['path']]['sha256']
            assert digest(path) == entry['sha256'], 'Changed: ' + entry['path']
            assert hashlib.sha256(archive.read(entry['path'])).hexdigest() == entry['sha256']
    deleted = []
    for entry in plan['delete_files']:
        path = safe_file(entry['path'])
        path.unlink()
        deleted.append(entry['path'])
    removed_directories = []
    for relative in plan['remove_empty_roots']:
        directory = ROOT / relative
        assert directory.resolve().is_relative_to(ROOT.resolve())
        assert directory.parent == ROOT / 'build_out'
        if directory.is_symlink() or directory.is_junction():
            raise ValueError('Refuse link root: ' + relative)
        for parent, directories, files in os.walk(directory, topdown=False, followlinks=False):
            current = Path(parent)
            if current.is_junction() or current.is_symlink():
                raise ValueError('Unexpected link: ' + str(current))
            if not any(current.iterdir()):
                current.rmdir()
                removed_directories.append(current.relative_to(ROOT).as_posix())
    result = {
        'deleted_count': len(deleted), 'deleted_bytes': plan['bytes'],
        'deleted_files': deleted, 'removed_empty_directories': removed_directories,
        'backup': plan['backup']['archive'], 'backup_sha256': plan['backup']['archive_sha256'],
    }
    (HERE / 'cleanup_result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: result[k] for k in ('deleted_count', 'deleted_bytes', 'backup')}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    apply_plan() if args.apply else build_plan()
