`timescale 1ns/1ps
module tb_vendor_cdc;
integer burst_count=256,burst_gap=16;initial begin if($value$plusargs("BURSTS=%d",burst_count))begin end if($value$plusargs("GAP=%d",burst_gap))begin end end
reg clk=0,reset=1;always #10 clk=~clk;
reg mc=0,ms=0;always #12.5 mc=~mc;initial begin #10;forever #12.5 ms=~ms;end
wire locked=1;wire init,busy,refresh,rv;wire[31:0]rd;
reg we=0,re=0;reg[20:0]wa=0,ra=0;reg[31:0]wd=0;
// Clock periods/offset measured with the vendor PLL model in tb_pll_clocks.
wire cwe,full,overflow,idle;wire[20:0]cwa;wire[31:0]cwd;wire[3:0]cmask;
media_sdram_write_cdc bridge(clk,!reset,we,wa,4'd0,wd,full,overflow,mc,!reset,cwe,cwa,cmask,cwd,idle,busy,refresh);
sdram dut(.Clk(mc),.Clk_sft(ms),.Rst(reset||!locked),.Sdr_init_done(init),.Sdr_busy(busy),.Sdr_init_ref_vld(refresh),
.App_wr_en(cwe),.App_wr_addr(cwa),.App_wr_dm(cmask),.App_wr_din(cwd),.App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rv),.Sdr_rd_dout(rd));
integer b,i,got=0,errors=0;reg check=0;
function[31:0]pattern;input integer addr;begin pattern=32'h5ac30000 ^ (addr*32'h10201);end endfunction
always @(posedge mc) if(rv&&check)begin
 if(rd!==pattern(got))begin if(errors<12)$display("MISMATCH word=%d got=%h exp=%h",got,rd,pattern(got));errors=errors+1;end
 got=got+1;
end
initial begin
 #200;reset=0;wait(init);repeat(100)@(negedge clk);
 for(b=0;b<burst_count;b=b+1)begin
 @(negedge clk);
 for(i=0;i<128;i=i+1)begin while(full)begin we=0;@(negedge clk);end we=1;wa=b*128+i;wd=pattern(b*128+i);@(negedge clk);if($test$plusargs("PACE"))begin we=0;repeat(2)@(negedge clk);end end
 we=0;repeat(burst_gap==999 ? (b*37)%257 : burst_gap)@(negedge clk);end
 wait(idle);repeat(256)@(negedge mc);check=1;
 for(b=0;b<burst_count;b=b+1)begin
 if($test$plusargs("GATE"))while(busy || refresh)@(negedge mc);
 for(i=0;i<128;i=i+1)begin re=1;ra=b*128+i;@(negedge mc);end
 re=0;repeat(burst_gap==999 ? (b*37)%257 : burst_gap)@(negedge mc);end
 repeat(512)@(negedge mc);
 if(got==burst_count*128 && errors==0 && !overflow)$display("PASS vendor SDRAM all requested words");
 else $fatal(1,"vendor SDRAM returned=%d errors=%d",got,errors);
 $finish;
end
initial begin #50000000;$fatal(1,"timeout init=%b b=%d i=%d full=%b overflow=%b idle=%b bridge active=%b first=%b remaining=%d pending=%b rdvalid=%b blocks=%d/%d busy=%b refresh=%b cwe=%b",init,b,i,full,overflow,idle,bridge.burst_active,bridge.burst_first,bridge.burst_remaining,bridge.prefetch_pending,bridge.fifo_rd_valid,bridge.src_block_binary,bridge.dst_block_binary,busy,refresh,cwe);$finish;end
endmodule
