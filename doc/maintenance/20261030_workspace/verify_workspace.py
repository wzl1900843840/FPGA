"""Read-only content checks after the reviewed cleanup; writes audit reports here."""
from pathlib import Path
import collections
import hashlib
import importlib.util
import json
import os
import re
import urllib.parse

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
BACKUP = ROOT.parent / 'backups/workspace_cleanup_20261030'
ALLOWED = {
    'README.md', 'AGENTS.md', 'build_out/README.md', 'archive/README.md',
    'tools/workspace_layout.json', 'doc/README.md', 'doc/当前使用指南.md',
    'doc/隔离构建区.md', 'doc/工程结构与维护.md', 'tests/README.md',
    'tools/README.md', 'docs/README.md', 'doc/救援串口协议与接收端.md',
}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    before = json.loads((BACKUP / 'backup_manifest.json').read_text(encoding='utf-8'))
    cleanup = json.loads((HERE / 'cleanup_result.json').read_text(encoding='utf-8'))
    deleted = set(cleanup['deleted_files'])
    changes, unexpected, protected = [], [], []
    unchanged = 0
    for e in before['files']:
        rel = e['path']
        path = ROOT / rel
        if rel in deleted:
            if path.exists():
                unexpected.append('Deletion not applied: ' + rel)
            changes.append({'path': rel, 'kind': 'deleted_after_verified_backup'})
        elif not path.is_file():
            unexpected.append('Unexpected missing file: ' + rel)
        elif digest(path) != e['sha256']:
            changes.append({'path': rel, 'kind': 'updated_navigation' if rel in ALLOWED else 'unexpected_change'})
            if rel not in ALLOWED:
                unexpected.append('Unexpected modified file: ' + rel)
        else:
            unchanged += 1
            if rel.startswith(('src/', 'tools/', 'tests/', 'media/', 'config/', 'logs/')) and rel not in ALLOWED:
                protected.append(e)
    (HERE / 'file_changes.json').write_text(json.dumps(changes, ensure_ascii=False, indent=2), encoding='utf-8')
    (HERE / 'protected_baseline.json').write_text(json.dumps(protected, ensure_ascii=False, indent=2), encoding='utf-8')
    link_checks = []
    for e in before['junctions']:
        path = ROOT / e['path']
        actual = os.readlink(path) if path.is_junction() else None
        ok = actual == e['target']
        link_checks.append({'path': e['path'], 'target': actual, 'passed': ok})
        if not ok:
            unexpected.append('Junction changed: ' + e['path'])
    a = ROOT / 'src/user_source'
    b = ROOT / 'build_out/final_repair_candidate_20261030_21/user_source'
    source_files, source_diff = 0, []
    for path in a.rglob('*'):
        if path.is_file():
            source_files += 1
            other = b / path.relative_to(a)
            if not other.is_file() or digest(path) != digest(other):
                source_diff.append(path.relative_to(a).as_posix())
    project = ROOT / 'src/td_project/lab_ex5_i2s_v1.0.al'
    candidate_project = b.parent / 'td_project/lab_ex5_i2s_v1.0.al'
    def refs(path):
        text = path.read_text(encoding='utf-8-sig')
        section = re.search(r'<Source_Files\b[^>]*>(.*?)</Source_Files>', text, re.S).group(1)
        return re.findall(r'<File\b[^>]*\bPath="([^"]+)"', section)
    actual_refs, candidate_refs = refs(project), refs(candidate_project)
    bit = b.parent / 'best_result/lab_ex5_i2s_v1.0.bit'
    validation = json.loads((bit.parent / 'validation.json').read_text(encoding='utf-8'))
    bit_hash = digest(bit)
    if source_diff or collections.Counter(actual_refs) != collections.Counter(candidate_refs) or bit_hash != validation['bit_sha256']:
        unexpected.append('Current candidate source/reference/hash mismatch')
    # Create the target before checking links pointing to this report.
    (HERE / 'verification.json').write_text('{}', encoding='utf-8')
    spec = importlib.util.spec_from_file_location('doctor', ROOT / 'tools/workspace_doctor.py')
    doctor_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(doctor_module)
    doctor = doctor_module.inspect(HERE / 'protected_baseline.json')
    (HERE / 'workspace_doctor.json').write_text(json.dumps(doctor, ensure_ascii=False, indent=2), encoding='utf-8')
    if not doctor['passed']:
        unexpected.extend(doctor['errors'])
    extra_pages = [ROOT/'doc/工程框架.md', ROOT/'doc/历史资料索引.md', ROOT/'doc/当前串口协议.md', HERE/'README.md', ROOT/'build_out/README.md']
    extra_links = 0
    for page in extra_pages:
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', page.read_text(encoding='utf-8')):
            if target.startswith(('http:', 'https:', '#', 'mailto:')):
                continue
            path = page.parent / urllib.parse.unquote(target.split('#')[0].strip('<>'))
            if not path.exists():
                unexpected.append('Broken link: ' + str(page.relative_to(ROOT)) + ' -> ' + target)
            extra_links += 1
    categories = collections.Counter()
    for rel in deleted:
        category = 'trial_candidates_1_to_20' if rel.startswith('build_out/final_repair_candidate_20261030_') else (
            'historical_bits' if rel.startswith('archive/releases/') else
            'old_reference_video' if rel.endswith('.mp4') else
            'legacy_root_guide' if rel == '设计参考例程文档.md' else 'regenerable_root_outputs')
        categories[category] += 1
    render = json.loads((HERE/'sop_render.json').read_text(encoding='utf-8'))
    report = {
        'passed': not unexpected, 'scope': str(ROOT), 'backup_members': len(before['files']),
        'unchanged_original_files': unchanged, 'protected_files_checked': len(protected),
        'changed_navigation_files': sorted(e['path'] for e in changes if e['kind'] == 'updated_navigation'),
        'deleted_files': len(deleted), 'deleted_bytes': cleanup['deleted_bytes'],
        'deletion_categories': dict(categories), 'junctions': link_checks,
        'current_candidate': {'source_files_compared': source_files, 'source_mismatches': source_diff,
            'active_td_entries': len(actual_refs), 'candidate_td_entries': len(candidate_refs),
            'source_reference_order_identical': actual_refs == candidate_refs,
            'source_reference_multiset_identical': collections.Counter(actual_refs) == collections.Counter(candidate_refs),
            'bit_sha256': bit_hash, 'validation_bit_matches': bit_hash == validation['bit_sha256'],
            'timing_ns': validation['timing_ns'], 'hardware_tested': validation['hardware_tested']},
        'doctor_passed': doctor['passed'], 'extra_links_checked': extra_links,
        'sop_render': render, 'unexpected_changes': unexpected,
        'not_performed': ['RTL or app behavior edits', 'synthesis', 'place/route', 'flashing', 'UART commands', 'hardware testing', 'git commit'],
    }
    (HERE / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
