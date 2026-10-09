`timescale 1ns/1ps
module tb_cache;
reg clk=0;always #5 clk=~clk;
reg rst=0,start=0;wire busy,done;wire[7:0]error;wire re,we;wire[20:0]ra,wa;wire[31:0]wd;
reg rv=0;reg [31:0]rd=0;integer count=0,pos,x,y,bank,sx,sy,expected;
thumbnail_cache_builder dut(clk,rst,start,4'b1101,busy,done,error,re,ra,rv,rd,we,wa,wd,1'b0,1'b0,1'b1,,);
// Independent address-pattern memory. Every source word encodes its own address.
always @(posedge clk) begin rv<=re;rd<=ra;
 if(we) begin
  if(wa!==1228800+count)$fatal(1,"write address %d %d",wa,count);
  pos=count;x=pos%640;y=pos/640;expected=0;
  if(x<320 && y<240)begin bank=(y/120)*2+x/160;sx=(x%160)*4;sy=(y%120)*4;
   if(bank!=1)expected=bank*307200+sy*640+sx;end
  if(wd!==expected)$fatal(1,"cache x%d y%d got%d expected%d",x,y,wd,expected);
  count=count+1;
 end
end
initial begin #12;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(error ||count!=307200)$fatal(1,"finish %d %d",error,count);
$display("PASS cache: all 307200 pixels, 4 banks, missing bank, 4:1 sampling");$finish;end
initial begin #30000000;$fatal(1,"watchdog");end
endmodule
