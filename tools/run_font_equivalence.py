"""Exhaustively compare all Chinese ROM addresses with the stage-5 checkpoint."""
from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'tests/results/font_equivalence';out.mkdir(parents=True,exist_ok=True)
baseline=subprocess.check_output(['git','show','80dcde8:src/user_source/rtl/promax_text_overlay.v'],cwd=ROOT).decode('utf-8')
(out/'baseline.v').write_text(baseline.replace('module promax_text_overlay #(','module baseline_text_overlay #('),encoding='utf-8')
(out/'tb_font_equivalence.v').write_text('''module tb_font_equivalence;
baseline_text_overlay old_font();promax_text_overlay new_font();
integer g,r;
initial begin
 for(g=0;g<32;g=g+1)for(r=0;r<16;r=r+1)
  if(old_font.chinese_glyph_row(g,r)!==new_font.chinese_glyph_row(g,r))
   $fatal(1,"glyph mismatch id=%0d row=%0d",g,r);
 $display("PASS Chinese font equivalence: all 512 addresses including unused ID31");$finish;
end
endmodule
''')
source=ROOT/'src/user_source/rtl/promax_text_overlay.v'
subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_font_equivalence','-o',str(out/'font.vvp'),
                str(out/'tb_font_equivalence.v'),str(out/'baseline.v'),str(source)],check=True)
p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(out/'font.vvp')],capture_output=True,text=True,timeout=30)
log=p.stdout+p.stderr;(out/'result.log').write_text(log);print(log);p.check_returncode()
if 'PASS Chinese font equivalence:' not in log:raise RuntimeError('Missing PASS')
(out/'summary.json').write_text(json.dumps(dict(passed=True,addresses=512,baseline_commit='80dcde8',
 source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()),indent=2))
