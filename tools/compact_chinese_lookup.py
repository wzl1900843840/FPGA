"""Replace the wide glyph mux with an equivalent sparse row-address ROM."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
target=ROOT/'src/user_source/rtl/promax_text_overlay.v'
source=target.read_text(encoding='utf-8')
glyphs={int(i):int(h,16 if base=='h' else 2) for i,base,h in re.findall(r"CN_GLYPH_(\d+)\s*=\s*256'([bh])([0-9a-fA-F]+)",source)}
if len(glyphs)!=31:raise RuntimeError('Expected all 31 existing glyph constants')
rows={}
for glyph,bits in sorted(glyphs.items()):
    for row in range(16):
        value=(bits>>((15-row)*16))&65535
        if value:rows.setdefault(value,[]).append((glyph<<4)|row)
lines=['    function [15:0] chinese_glyph_row;', '        input [4:0] glyph_id;', '        input [3:0] row;',
       '        begin', '            // Sparse 9-bit row address, avoiding a 256-bit intermediate mux.',
       '            case ({glyph_id,row})']
for value,addresses in sorted(rows.items()):
    labels=','.join(f"9'h{a:03x}" for a in addresses)
    lines.append(f"                {labels}: chinese_glyph_row=16'h{value:04x};")
lines+=['                default: chinese_glyph_row=0;', '            endcase', '        end', '    endfunction']
source,count=re.subn(r'    function \[15:0\] chinese_glyph_row;.*?    endfunction','\n'.join(lines),source,flags=re.S)
if count!=1:raise RuntimeError('Expected one lookup function')
target.write_text(source,encoding='utf-8')
print(f'Generated {sum(map(len,rows.values()))} nonzero rows, {len(rows)} unique words; glyph bytes unchanged')
