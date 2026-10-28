"""Prepare an isolated TD build tree under build_out/ so generated files never enter src/.

The copy is derived, never edited by hand: rerun this script to refresh it after any
change to src/td_project/*.al, settings.cfg or the RTL. src/user_source is shared through a
directory junction (or copied with --link-mode copy), so RTL is single-source.
"""
from pathlib import Path
import argparse, os, re, shutil, subprocess, sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
SRC_PROJECT = SRC / 'td_project'
SRC_USER = SRC / 'user_source'
DEFAULT_OUT = ROOT / 'build_out'
PROJECT_NAME = 'lab_ex5_i2s_v1.0'

# Engine scratch, logs and run products: everything that must stay out of src/.
GENERATED_SUFFIXES = ('.db', '.area', '.timing', '.ts', '.qor', '.log', '.logw', '.vvp', '.bit', '.bid', '.dmp')
GENERATED_NAMES = {'.lock.f', 'build_console.log', 'place_route_console.log', 'inspect_commands.log',
                   'inspect_routed.log', 'ipst.log', 'final_timing.rpt', 'flow.status',
                   'place_flow.status', 'route_flow.status'}


def is_generated(name):
    return name.startswith('td_') or name.startswith('.') or name in GENERATED_NAMES or name.endswith(GENERATED_SUFFIXES)


def clear_dir(path):
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def copy_project(dst_project):
    clear_dir(dst_project)
    for item in sorted(SRC_PROJECT.iterdir(), key=lambda p: p.name):
        if item.is_dir():
            if item.name.endswith('_Runs') or item.name == 'build_complete':
                # Copy the run scaffolding (settings.cfg/.prj/run.bat) only; drop products.
                for stage in sorted(item.iterdir()):
                    if not stage.is_dir():
                        continue
                    stage_dir = dst_project / item.name / stage.name
                    stage_dir.mkdir(parents=True, exist_ok=True)
                    for cfg in sorted(stage.iterdir()):
                        if cfg.is_file() and not is_generated(cfg.name):
                            shutil.copy2(cfg, stage_dir / cfg.name)
            else:
                shutil.copytree(item, dst_project / item.name)
        elif not is_generated(item.name):
            shutil.copy2(item, dst_project / item.name)


def run_dir(dst_project, stage):
    path = dst_project / f'{PROJECT_NAME}_Runs' / stage
    if not path.is_dir():
        raise SystemExit('missing run scaffolding: ' + str(path))
    return path


def apply_phy_strategy(dst_project):
    """Reinject the physical strategy the current verified bit was built with.

    Those set_param calls were configured in the TD GUI and are not stored in the copied
    settings.cfg, so an isolated run would silently fall back to medium effort. Read them
    back from the previous run log when it exists, otherwise use the recorded strategy.
    """
    params = {}
    for log in sorted((SRC_PROJECT / f'{PROJECT_NAME}_Runs/phy_1').glob('*.log'),
                      key=lambda p: p.stat().st_mtime):
        for key, value in re.findall(
                r'start command "set_param (place effort|place opt_timing|route effort) (\w+)"',
                log.read_text(encoding='utf-8', errors='replace')):
            params[key] = value
    if not params:
        params = {'place effort': 'high', 'place opt_timing': 'high', 'route effort': 'high'}
    wild = ' '.join(f'{key} {value}' for key, value in params.items())
    line = f'set phyWildParams {{{wild}}}'
    cfg = run_dir(dst_project, 'phy_1') / 'settings.cfg'
    text = cfg.read_text(encoding='utf-8')
    if 'phyWildParams' not in text:
        cfg.write_text(text.rstrip('\n') + '\n' + line + '\n', encoding='utf-8')
    return line


def link_user_source(dst_user, mode):
    """Return the mode actually used: junction or copy."""
    if os.path.lexists(dst_user):
        if dst_user.is_symlink():
            os.rmdir(dst_user)
        else:
            shutil.rmtree(dst_user)
    if mode in ('junction', 'auto') and os.name == 'nt':
        result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(dst_user), str(SRC_USER)],
                                capture_output=True, text=True)
        probe = dst_user / 'rtl' / 'afifo_32_16_256.v'
        if result.returncode == 0 and probe.is_file():
            return 'junction'
        if mode == 'junction':
            raise SystemExit('mklink /J failed: ' + (result.stdout + result.stderr).strip())
        if os.path.lexists(dst_user):
            os.rmdir(dst_user)
    shutil.copytree(SRC_USER, dst_user)
    return 'copy'


def rewrite_paths(dst_project):
    """Point absolute project paths at the isolated tree; leave all relative paths untouched."""
    old = SRC_PROJECT.as_posix()
    new = dst_project.as_posix()
    changed = []
    for name in (PROJECT_NAME + '.al',):
        target = dst_project / name
        text = target.read_text(encoding='utf-8')
        if old not in text:
            raise SystemExit(f'{name} does not reference {old}; refusing to guess')
        target.write_text(text.replace(old, new), encoding='utf-8')
        changed.append(name)
    for prj in sorted((dst_project / f'{PROJECT_NAME}_Runs').rglob('*.prj')):
        text = prj.read_text(encoding='utf-8')
        # TD's standalone flow opens .prj, not .al. Always derive its source
        # set from the authoritative project instead of reusing stale GUI runs.
        al_text=(dst_project/(PROJECT_NAME+'.al')).read_text(encoding='utf-8')
        block=re.search(r'<Source_Files>.*?</Source_Files>',al_text,re.S)[0]
        block=block.replace('../user_source/','../../../user_source/').replace('UsedInP&amp;R','UsedInP&R')
        text=re.sub(r'<Source_Files>.*?</Source_Files>',lambda _:block,text,flags=re.S)
        prj.write_text(text,encoding='utf-8')
        if old in text:
            prj.write_text(text.replace(old, new), encoding='utf-8')
            changed.append(str(prj.relative_to(dst_project)))
    return changed


def verify(dst_project):
    """Prove every source reference in the isolated .al resolves to a real file."""
    al = dst_project / (PROJECT_NAME + '.al')
    text = al.read_text(encoding='utf-8')
    refs = re.findall(r'<File Path="([^"]+)"', text)
    if not refs:
        raise SystemExit('no source references found in ' + str(al))
    missing = [ref for ref in refs if not (dst_project / ref).is_file()]
    if missing:
        raise SystemExit('isolated tree is incomplete, missing:\n  ' + '\n  '.join(missing))
    adc = dst_project / 'lab_ex5_i2s_v1.0_Runs/phy_1/settings.cfg'
    if not adc.is_file():
        raise SystemExit('missing run scaffolding: ' + str(adc))
    return refs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT, help='isolated build root (default build_out)')
    parser.add_argument('--link-mode', choices=('auto', 'junction', 'copy'), default='auto',
                        help='how src/user_source is shared into the isolated tree')
    args = parser.parse_args()
    out = args.out.resolve()
    if ROOT not in out.parents and out != ROOT:
        raise SystemExit('refusing to write outside the workspace: ' + str(out))
    out.mkdir(parents=True, exist_ok=True)
    dst_project = out / 'td_project'
    copy_project(dst_project)
    mode = link_user_source(out / 'user_source', args.link_mode)
    changed = rewrite_paths(dst_project)
    strategy = apply_phy_strategy(dst_project)
    # The synchronous OSD font ROM must retain its configuration bits.
    # DefaultFlow forwards these documented stage/key/value triples.
    syn_cfg=run_dir(dst_project, 'syn_1')/'settings.cfg'
    cfg=syn_cfg.read_text(encoding='utf-8')
    cfg=re.sub(r'^set synWildParams .*\n?', '', cfg, flags=re.M)
    syn_cfg.write_text(cfg.rstrip('\n')+'\nset synWildParams {gate eram_init on}\n',encoding='utf-8')
    refs = verify(dst_project)
    print(f'isolated tree : {out}')
    print(f'project copy  : {dst_project}')
    print(f'user_source   : {mode}')
    print(f'path rewrites : {len(changed)} file(s)')
    print(f'phy strategy  : {strategy}')
    print(f'source refs   : {len(refs)} verified present')
    print(f'next          : python tools/build_isolated.py')
    return 0


if __name__ == '__main__':
    sys.exit(main())
