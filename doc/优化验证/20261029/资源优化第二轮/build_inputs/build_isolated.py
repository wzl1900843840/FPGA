"""Build, check timing and publish a release from the isolated build_out tree.

Every engine product (logs, scratch .qor, runs, bit) lands under build_out/; src/ is only
read. Run tools/setup_isolated_build.py first, and rerun it after any project or RTL change.
"""
from pathlib import Path
import argparse, hashlib, json, re, shutil, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[1]
TD_DEFAULT = Path('E:/Anlogic/TD_6.2.1_Engineer_6.2.168.116')
NAME = 'lab_ex5_i2s_v1.0'
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build import reviewed_warning  # noqa: E402  (shared, reviewed-warning policy)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_files(root):
    files = [p for p in (root / 'src/user_source').rglob('*')
             if p.suffix in ('.v', '.vh', '.sdc', '.adc')]
    return files


def snapshot_hashes(out, frozen=False):
    """Hash the actual build inputs; reject a stale copy before invoking TD."""
    hashes = {}
    sources=source_files(ROOT) if not frozen else [ROOT/'src/user_source'/p.relative_to(out/'user_source') for p in (out/'user_source').rglob('*') if p.suffix in ('.v','.vh','.sdc','.adc')]
    for source in sorted(sources):
        relative = source.relative_to(ROOT / 'src/user_source')
        snapshot = out / 'user_source' / relative
        if not snapshot.is_file() or (not frozen and digest(snapshot) != digest(source)):
            raise SystemExit('isolated source is stale: ' + str(relative))
        hashes[str(source.relative_to(ROOT))] = digest(snapshot)
    return hashes


def run_flow(td_root, workdir, log, flow=None):
    flow = flow or td_root / 'doc/scripts/DefaultFlow.tcl'
    exe = td_root / 'bin/td_commands_prompt.exe'
    for path in (exe, flow):
        if not path.is_file():
            raise SystemExit('TD installation incomplete, missing ' + str(path))
    print(f'Running TD flow in {workdir}', flush=True)
    with log.open('w', encoding='utf-8') as handle:
        result = subprocess.run([str(exe), flow.as_posix()], cwd=str(workdir),
                                stdout=handle, stderr=subprocess.STDOUT)
    text = log.read_text(encoding='utf-8', errors='replace')
    if (result.returncode or re.search(r'\b(?:ERROR|FATAL)\s*:', text)
            or "couldn't read file" in text or 'invalid command name' in text):
        raise SystemExit(f'TD failed in {workdir.name}; inspect {log}')
    critical = [line for line in text.splitlines()
                if 'CRITICAL-WARNING' in line and not reviewed_warning(line, text)]
    if critical:
        raise SystemExit('unreviewed critical warnings:\n  ' + '\n  '.join(critical))
    if 'export_db' not in text:
        raise SystemExit(f'TD did not complete {workdir.name}; inspect {log}')
    return [line for line in text.splitlines() if 'WARNING' in line]


def check_tree(out, frozen=False):
    project = out / 'td_project'
    al = project / (NAME + '.al')
    if not al.is_file():
        raise SystemExit('isolated tree missing; run tools/setup_isolated_build.py')
    pattern = r'<File Path="([^"]+)"'
    isolated = re.findall(pattern, al.read_text(encoding='utf-8'))
    current = re.findall(pattern, (ROOT / 'src/td_project' / (NAME + '.al')).read_text(encoding='utf-8'))
    if isolated != current and not frozen:
        raise SystemExit('isolated project is stale; rerun tools/setup_isolated_build.py')
    if not (out / 'user_source').exists():
        raise SystemExit('isolated user_source link is missing; rerun setup_isolated_build.py')
    expected={str((project/ref).resolve()).lower() for ref in isolated}
    for stage in ('syn_1','phy_1'):
        prj=project/f'{NAME}_Runs'/stage/(NAME+'.prj')
        refs=re.findall(pattern,prj.read_text(encoding='utf-8'))
        actual={str((prj.parent/ref).resolve()).lower() for ref in refs}
        if actual!=expected or any(not Path(ref).is_file() for ref in actual):
            raise SystemExit('run source list mismatches authoritative .al: '+str(prj))
    if 'gate eram_init on' not in (project/f'{NAME}_Runs/syn_1/settings.cfg').read_text(encoding='utf-8'):
        raise SystemExit('BRAM font initialization is disabled')
    return project / f'{NAME}_Runs'


def timing_values(path):
    text = path.read_text(errors='replace')
    return {key: float(re.search(key + r':\s*(-?[\d.]+)ns', text)[1])
            for key in ('SWNS', 'STNS', 'HWNS', 'HTNS')}


def publish(out, runs, values, hashes, warnings):
    phy = runs / 'phy_1'
    best = out / 'best_result'
    best.mkdir(parents=True, exist_ok=True)
    bit = phy / (NAME + '.bit')
    if not bit.is_file():
        raise SystemExit('no bitstream produced: ' + str(bit))
    for name in (NAME + '.bit', NAME + '_phy.ts', NAME + '_inst.bid', NAME + '_phy.area',
                 NAME + '_pr.timing', NAME + '_exception.timing', 'final_timing.rpt',
                 'place.qor', 'route.qor', 'place_flow.status', 'route_flow.status',
                 'place_clock_utilization.txt', 'route_clock_utilization.txt'):
        if (phy / name).is_file():
            shutil.copy2(phy / name, best / name)
    for name in ('timing_checks.rpt', 'hold_parameters.txt', 'hold_repair.log'):
        if (phy / name).is_file():
            shutil.copy2(phy / name, best / name)
    (best / 'readMe.txt').write_text('The implemented result of phy_1 is saved as best result.\n',
                                     encoding='utf-8')
    report = {
        'built_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'isolated_build_root': str(out),
        'bit_sha256': digest(bit),
        'timing_ns': values,
        'sources': hashes,
        'build_inputs': {
            str(p.relative_to(ROOT)): digest(p) for p in
            [out / 'td_project' / (NAME + '.al'),
             ROOT / 'tools/build_isolated.py', ROOT / 'tools/setup_isolated_build.py',
             ROOT / 'tools/repair_routed_hold.tcl',
             runs / 'syn_1/settings.cfg', runs / 'phy_1/settings.cfg',
             runs / 'syn_1'/(NAME+'.prj'), runs / 'phy_1'/(NAME+'.prj')]
        },
        'warnings': warnings,
        'hardware_tested': False,
        'note': 'Source hashes and project describe the actual isolated copy. Tool script hashes describe collection-time tooling.',
    }
    (best / 'validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2),
                                          encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'sources'}, ensure_ascii=False, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'build_out')
    parser.add_argument('--td-root', type=Path, default=TD_DEFAULT)
    parser.add_argument('--physical-only', action='store_true',
                        help='reuse the isolated syn_1 result; only rerun place and route')
    parser.add_argument('--collect', action='store_true',
                        help='verify and publish an already finished isolated run')
    parser.add_argument('--frozen-source', action='store_true', help='build/check immutable source copy while worktree advances')
    args = parser.parse_args()
    out = args.out.resolve()
    runs = check_tree(out,args.frozen_source)
    hashes = snapshot_hashes(out,args.frozen_source)
    warnings = []
    if not args.collect:
        for stage in (('phy_1',) if args.physical_only else ('syn_1', 'phy_1')):
            stage_dir = runs / stage
            if not (stage_dir / 'settings.cfg').is_file():
                raise SystemExit(f'missing run scaffolding for {stage}: {stage_dir}')
            warnings += run_flow(args.td_root, stage_dir, stage_dir / 'isolated_build.log')
        # Explicit native post-route hold repair is necessary for RAM address
        # paths which TD's ordinary route pass can leave slightly negative.
        phy = runs / 'phy_1'
        warnings += run_flow(args.td_root, phy, phy / 'hold_repair.log',
                             ROOT / 'tools/repair_routed_hold.tcl')
    else:
        for stage, name in (('syn_1', 'isolated_build.log'),
                            ('phy_1', 'isolated_build.log'), ('phy_1', 'hold_repair.log')):
            log = (runs / stage / name).read_text(encoding='utf-8', errors='replace')
            if re.search(r'\b(?:ERROR|FATAL)\s*:', log):
                raise SystemExit('error in collected build log: ' + name)
            if any('CRITICAL-WARNING' in line and not reviewed_warning(line, log)
                   for line in log.splitlines()):
                raise SystemExit('unreviewed critical warning in: ' + name)
            warnings += [line for line in log.splitlines() if 'WARNING' in line]
    for name, value in hashes.items():
        checked=(out/'user_source'/Path(name).relative_to('src/user_source')) if args.frozen_source else ROOT/name
        if digest(checked) != value:
            raise SystemExit('source changed during the build: ' + name)
    values = timing_values(runs / 'phy_1' / (NAME + '_pr.timing'))
    if min(values.values()) < 0:
        raise SystemExit('routed timing failed: ' + str(values))
    checks = (runs / 'phy_1/timing_checks.rpt').read_text(errors='replace')
    for section in ('no clock', 'clock definition', 'invalid constraint',
                    'combinational loops', 'no path constraints'):
        match = re.search(r'checking ' + section + r'\((\d+)\)', checks)
        if match is None or int(match[1]):
            raise SystemExit('unresolved timing check: ' + section)
    # This section's heading counts inspected PLL instances, not violations.
    pll_checks = re.findall(r'There are (\d+) (?:clock pins that have no clock constraints|clocks whose clock frequency do not match the PLL setting)', checks)
    if len(pll_checks) < 2 or any(int(n) for n in pll_checks):
        raise SystemExit('unresolved PLL clock constraints')
    publish(out, runs, values, hashes, warnings)
    return 0


if __name__ == '__main__':
    sys.exit(main())
