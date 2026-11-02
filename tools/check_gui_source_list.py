"""Fail fast when TD GUI run files omit an active RTL source or font init."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
project = root / 'src/td_project'
name = 'lab_ex5_i2s_v1.0'
al = project / f'{name}.al'


def design_sources(path):
    text = path.read_text(encoding='utf-8')
    # TD's .al/.prj contains a literal "UsedInP&R" attribute, so it is not
    # strict XML. Read only the File Path attributes used by TD's own scripts.
    refs = [ref for ref in re.findall(r'<File Path="([^"]+)"', text)
            if ref.lower().endswith(('.v', '.vh'))]
    paths = [(path.parent / ref).resolve() for ref in refs]
    if len(paths) != len(set(paths)):
        raise SystemExit(f'duplicate source in {path}')
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        raise SystemExit(f'missing files in {path}: {missing}')
    return text, set(paths)


al_text, expected = design_sources(al)
secure = (root / 'src/user_source/rtl/uart_secure_ingress_bram.v').resolve()
if secure not in expected:
    raise SystemExit('GUI .al omits uart_secure_ingress_bram.v')
for stage in ('syn_1', 'phy_1'):
    prj = project / f'{name}_Runs' / stage / f'{name}.prj'
    _, actual = design_sources(prj)
    if actual != expected:
        raise SystemExit(f'{stage} source list differs from .al: '
                         f'missing={sorted(map(str, expected-actual))}, '
                         f'extra={sorted(map(str, actual-expected))}')

if not re.search(r'<Run Name="syn_1"[\s\S]*?<GateProperty>\s*<eram_init>on</eram_init>', al_text):
    raise SystemExit('GUI .al does not enable ERAM font initialization')
cfg = (project / f'{name}_Runs/syn_1/settings.cfg').read_text(encoding='utf-8')
if 'gate eram_init on' not in cfg:
    raise SystemExit('GUI syn_1 settings.cfg does not enable ERAM font initialization')
print(f'PASS GUI source list: {len(expected)} design files, secure ingress registered, '
      'syn_1/phy_1 match, ERAM init enabled')
