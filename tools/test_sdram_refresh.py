"""Check the vendor's visible refresh counter, without decrypting its IP body."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / 'tests/results/sdram_refresh'
out.mkdir(parents=True, exist_ok=True)
source = root / 'src/user_source/hdl_source/include/sdr_init_ref.enc.v'
# Only the public counter/request logic preceding the protected command encoder.
public = source.read_text(encoding='utf-8').split('`pragma protect begin_protected')[0]
(out / 'refresh_public.v').write_text(public + '\nendmodule\n', encoding='utf-8')
(out / 'tb_refresh.v').write_text('''`timescale 1ns/1ps
module tb_refresh;
reg clk=0, rst=1, ack=0;
always #12.5 clk=~clk;
wire done, req;
integer cycle=0, last=-1, requests=0;
sdr_init_ref dut(.Sdr_clk(clk),.Rst(rst),.Sdr_init_req(1'b0),
 .Sdr_init_mode(4'd7),.App_ref_req(1'b0),.Sdr_ref_req(req),
 .Sdr_ref_ack(ack),.Sdr_rw_vld(1'b0),.Sdr_init_done(done));
always @(posedge clk) begin
 cycle=cycle+1;
 ack<=req;
 if(done && req) begin
  if(last>=0 && cycle-last!=1250) $fatal(1,"Refresh spacing %0d, expected 1250 clocks",cycle-last);
  last=cycle; requests=requests+1;
  if(requests==8) begin
   $display("PASS SDRAM refresh: 8 requests, 1250 clocks (31.25 us) apart, 2048 rows / 64 ms");
   $finish;
  end
 end
 if(cycle>150000) $fatal(1,"No periodic refresh: requests=%0d interval=%0d",requests,`SELF_REFRESH_INTERVAL);
end
initial begin repeat(4) @(negedge clk);rst=0;end
endmodule
''', encoding='utf-8')
binary=out/'refresh.vvp'
cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_refresh','-o',str(binary),
     str(out/'refresh_public.v'),str(out/'tb_refresh.v')]
c=subprocess.run(cmd,cwd=root/'src/td_project',capture_output=True,text=True)
log=c.stdout+c.stderr
if c.returncode==0:
 c=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True,timeout=30)
 log+=c.stdout+c.stderr
(out/'result.log').write_text(log,encoding='utf-8')
print(log)
raise SystemExit(c.returncode)
