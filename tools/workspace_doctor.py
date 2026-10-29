"""Read-only structure checks; never build, flash, contact devices or remove files."""
from pathlib import Path
import argparse
import ast
import hashlib
import html
import json
import re
import shutil
import struct
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project_entries(text):
    # TD writes literal '&' in attribute values such as UsedInP&R.
    # Read only its source/top sections; never rewrite the vendor project.
    sources = re.search(r'<Source_Files\b[^>]*>(.*?)</Source_Files>',text,re.S)
    top = re.search(r'<TOP_MODULE\b[^>]*>(.*?)</TOP_MODULE>',text,re.S)
    if sources is None or top is None:
        raise ValueError('Missing Source_Files or TOP_MODULE section')
    refs = [html.unescape(ref) for ref in
            re.findall(r'<File\b[^>]*\bPath="([^"]+)"',sources.group(1))]
    module = re.search(r'<MODULE>\s*([^<]+?)\s*</MODULE>',top.group(1))
    if not refs or module is None or module.group(1) != 'top':
        raise ValueError('Empty source list or unexpected top module')
    return refs


def inspect(baseline=None):
    layout = json.loads((ROOT/'tools/workspace_layout.json').read_text(encoding='utf-8'))
    errors, notes, refs = [], [], []
    project = ROOT/layout['project']
    try:
        refs = project_entries(project.read_text(encoding='utf-8-sig'))
        for ref in refs:
            if not (project.parent/ref).resolve().is_file():
                errors.append('Missing TD source: '+ref)
    except (OSError, ValueError) as exc:
        errors.append('TD project entries: '+str(exc))
    required = [layout['top'], *layout['constraints'], *layout['launchers'],
                'tools/build_gui.py','tools/setup_isolated_build.py','tools/build_isolated.py',
                'tools/repair_routed_hold.tcl','tools/run_tests.py','tools/launch_console.py',
                'tools/stairwell_watch.py','tools/host_app/__init__.py',
                'tests/results/hardware_pass_20260928/validation.json']
    for rel in required:
        if not (ROOT/rel).is_file():
            errors.append('Missing entry: '+rel)
    python_count = 0
    for directory in ['tools','tests']:
        for path in (ROOT/directory).rglob('*.py'):
            if 'results' in path.relative_to(ROOT).parts:
                continue
            try:
                ast.parse(path.read_text(encoding='utf-8-sig'),filename=str(path))
                python_count += 1
            except (OSError, SyntaxError) as exc:
                errors.append('Python parse: '+str(exc))
    for rel in ['build_out','tests/results','logs','config']:
        if not (ROOT/rel).is_dir():
            errors.append('Missing runtime directory: '+rel)
    bit = ROOT/layout['previous_verified_build']/'lab_ex5_i2s_v1.0.bit'
    if bit.is_file():
        if digest(bit) != layout['previous_verified_bit_sha256']:
            errors.append('Retained accepted BIT hash changed')
        notes.append('Retained accepted BIT predates current OSD; rebuild after source edits')
    else:
        notes.append('Optional previous local build unavailable; see archived evidence in doc')
    media_info = []
    media = Path(layout['current_media'])
    if media.is_dir():
        for n in range(1,6):
            p = media/f'PIC{n}.BMP'
            try:
                data = p.read_bytes()
                sig,size,_,_,off = struct.unpack_from('<2sIHHI',data)
                dib,w,h,planes,bpp,comp = struct.unpack_from('<IiiHHI',data,14)
                if (sig!=b'BM' or size!=len(data) or off!=54 or dib!=40 or planes!=1
                        or bpp!=24 or comp!=0 or (w,h) not in ((640,480),(1280,960))
                        or len(data)!=54+w*h*3):
                    errors.append('Invalid BMP: '+str(p))
                media_info.append({'file':p.name,'size':[w,h],'sha256':digest(p)})
            except (OSError,struct.error) as exc:
                errors.append('Media: '+str(exc))
    else:
        notes.append('External current media not installed on this machine')
    baseline_count = 0
    if baseline:
        for entry in json.loads(baseline.read_text(encoding='utf-8')):
            p = ROOT/entry['path']
            if not p.is_file() or digest(p)!=entry['sha256']:
                errors.append('Protected file changed: '+entry['path'])
            baseline_count += 1
    pages = ['README.md','AGENTS.md','doc/README.md','docs/README.md','tools/README.md',
             'tests/README.md','media/README.md','archive/README.md',
             'doc/当前使用指南.md','doc/开发指南.md','doc/工程结构与维护.md',
             'doc/隔离构建区.md','代码说明.md',
             'doc/maintenance/20261029_workspace/README.md',
             'docs/历史档案/需求归档/工程目录整理_20261029需求.md',
             'docs/历史档案/任务归档/工程目录整理_20261029设计.md',
             'docs/历史档案/任务归档/工程目录整理_20261029任务.md']
    links = 0
    for rel in pages:
        p = ROOT/rel
        if not p.is_file():
            errors.append('Missing navigation: '+rel)
            continue
        for raw in re.findall(r'\[[^\]]*\]\(([^)]+)\)',p.read_text(encoding='utf-8')):
            url = raw.strip().strip('<>')
            if url.startswith(('http:','https:','app:','#','mailto:')):
                continue
            url = urllib.parse.unquote(url.split('#')[0])
            if url and not (p.parent/url).exists():
                errors.append('Broken link in '+rel+': '+url)
            links += 1
    notes.append('Structure checks do not prove timing closure or hardware acceptance')
    return {'passed':not errors,'project':layout['project'],'td_references':len(refs),
            'python_files_parsed':python_count,'navigation_links_checked':links,
            'protected_files_checked':baseline_count,'current_media':media_info,
            'tools':{'python':sys.executable,'iverilog':shutil.which('iverilog'),'vvp':shutil.which('vvp')},
            'errors':errors,'notes':notes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,help='Optional protected-file hash list')
    args = parser.parse_args()
    report = inspect(args.baseline.resolve() if args.baseline else None)
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
