`timescale 1ns/1ps
module tb_vendor_cache;
wire vi,vbusy,vref;reg ms=0;initial begin #10;forever #12.5 ms=~ms;end
reg clk=0;always #12.5 clk=~clk;
reg rst=0,start=0;wire busy,done;wire[7:0]error;wire re,we;wire[20:0]ra,wa;wire[31:0]wd;
wire rv;wire[31:0]rd;integer count=0,pos,x,y,bank,sx,sy,expected;
thumbnail_cache_builder dut(clk,rst,start,4'b1101,busy,done,error,re,ra,rv,rd,we,wa,wd,vbusy,vref,1'b1,,);
sdram vendor(.Clk(clk),.Clk_sft(ms),.Rst(!rst),.Sdr_init_done(vi),.Sdr_busy(vbusy),.Sdr_init_ref_vld(vref),
.App_wr_en(we),.App_wr_addr(wa),.App_wr_dm(4'd0),.App_wr_din(wd),.App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rv),.Sdr_rd_dout(rd));
// Independent address-pattern memory. Every source word encodes its own address.
always @(posedge clk) begin
 if(we) begin
  if(wa!==1228800+count)$fatal(1,"write address %d %d",wa,count);
  pos=count;x=pos%640;y=pos/640;expected=0;
  if(x>=160 && x<480 && y>=120 && y<360)begin bank=((y-120)/120)*2+(x-160)/160;sx=((x-160)%160)*4;sy=((y-120)%120)*4;
   if(bank!=1)expected=bank*307200+sy*640+sx;end
  if(wd!==expected)$fatal(1,"cache x%d y%d got%d expected%d",x,y,wd,expected);
  count=count+1;
 end
end
integer n;
initial begin #51;rst=1;wait(vi);
for(n=0;n<1228800;n=n+1)begin
case((n>>2)&3)
0:vendor.sdram.chip.Bank0[((n>>4)<<2)|(n&3)]=n;
1:vendor.sdram.chip.Bank1[((n>>4)<<2)|(n&3)]=n;
2:vendor.sdram.chip.Bank2[((n>>4)<<2)|(n&3)]=n;
3:vendor.sdram.chip.Bank3[((n>>4)<<2)|(n&3)]=n;
endcase end
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(error ||count!=307200)$fatal(1,"finish %d %d",error,count);
$display("PASS vendor cache: all 307200 pixels, 4 banks, missing bank, 4:1 sampling");$finish;end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
