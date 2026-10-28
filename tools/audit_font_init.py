"""Compare all 4096 font words with the eight mapped TD BRAM INIT vectors.

Export a completed synthesis database with audit_font_init.tcl first. This checks
the ROM content, not routed timing, physical configuration or display hardware.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--netlist', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
scratch = ROOT / 'build_out/font_init_audit'
scratch.mkdir(parents=True, exist_ok=True)
reference = scratch / 'reference.hex'
bench = scratch / 'dump_font.v'
bench.write_text('module dump_font;\n'
    'promax_text_overlay #(.MENU_ENABLE(1),.FONT_BRAM(1)) d();\n'
    'initial begin #1;$writememh("' + reference.as_posix() +
    '",d.g_font_bram.font_rom);$finish;end\nendmodule\n', encoding='utf-8')
rtl = ROOT / 'src/user_source/rtl/promax_text_overlay.v'
binary = scratch / 'dump_font.vvp'
subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'dump_font',
                '-o', str(binary), str(bench), str(rtl)], check=True)
subprocess.run(['D:/iverilog/bin/vvp.exe', str(binary)], check=True)
words = [int(line, 16) for line in reference.read_text().splitlines()
         if line.strip() and not line.startswith('//')]
assert len(words) == 4096
netlist = args.netlist.read_text(encoding='utf-8')
blocks = re.findall(r'EG_PHY_BRAM\s*#\((.*?)\);', netlist, re.S)
records = []
covered = set()
for block in blocks:
    if 'u_text/ramread0_syn_' not in block:
        continue
    bit_match = re.search(r'font_word\s*\[(\d+):(\d+)\]', block)
    assert bit_match, 'font output mapping is missing'
    high, low = map(int, bit_match.groups())
    assert high == low + 1 and not ({high, low} & covered)
    assert '.DATA_WIDTH_A("2")' in block and '.MODE("SP8K")' in block
    chunks = {int(i, 16): int(value, 16) for i, value in
              re.findall(r"\.INIT_([0-9A-F]{2})\(256'h([0-9a-fA-F]+)\)", block)}
    assert set(chunks) == set(range(32)), 'incomplete BRAM initialization'
    bits = sum(value << (256 * index) for index, value in chunks.items())
    mismatches = [address for address, word in enumerate(words)
                  if ((bits >> (2 * address)) & 3) != ((word >> low) & 3)]
    records.append(dict(font_bits=[high, low], mismatches=len(mismatches),
                        first=mismatches[:8]))
    covered.update((high, low))
assert len(records) == 8 and covered == set(range(16)), 'font banks are missing'
report = dict(netlist_sha256=hashlib.sha256(args.netlist.read_bytes()).hexdigest(),
              rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),
              reference_words=len(words),
              all_4096_words_match_mapped_init=all(r['mismatches'] == 0 for r in records),
              mapped_init_comparison=records,
              scope='Mapped ROM content only; not hardware acceptance or post-route simulation.')
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(report, indent=2), encoding='utf-8')
assert report['all_4096_words_match_mapped_init'], 'font INIT mismatch'
print('PASS font init: 4096 words, 8 mapped BRAM banks, zero mismatches')
