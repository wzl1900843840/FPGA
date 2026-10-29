`timescale 1ns/1ps
// Focused check of the mapped waveform DP8K geometry using Anlogic's model.
// Read and write banks differ, so same-address mixed-port behavior is unused.
module tb_resource_bram;
reg clk=0;always #5 clk=~clk;
reg we=0,bank=0;reg [5:0] wi=0,ri=0,rp=0;reg [6:0] wd=0;
wire [8:0] cur,prev;reg [6:0] memory[0:127];
integer i,rounds,checks=0;reg check_enable=0;reg [6:0] ec,ep;
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
 .CEAMUX("1"),.CEBMUX("1"),.OCEAMUX("1"),.OCEBMUX("1"),
 .CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RSTAMUX("0"),.RSTBMUX("0"),
 .WEBMUX("0")) a(
 .csa(3'b111),.csb(3'b111),.cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
 .rsta(1'b0),.rstb(1'b0),.web(1'b0),.dib(9'd0),.doa(),
 .clka(clk),.clkb(clk),.wea(we),.addra({3'b000,bank,wi,3'b111}),
 .addrb({3'b000,~bank,ri,3'b111}),.dia({2'b00,wd}),.dob(cur));
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
 .CEAMUX("1"),.CEBMUX("1"),.OCEAMUX("1"),.OCEBMUX("1"),
 .CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RSTAMUX("0"),.RSTBMUX("0"),
 .WEBMUX("0")) b(
 .csa(3'b111),.csb(3'b111),.cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
 .rsta(1'b0),.rstb(1'b0),.web(1'b0),.dib(9'd0),.doa(),
 .clka(clk),.clkb(clk),.wea(we),.addra({3'b000,bank,wi,3'b111}),
 .addrb({3'b000,~bank,rp,3'b111}),.dia({2'b00,wd}),.dob(prev));
always @(posedge clk)begin
 ec=memory[{~bank,ri}];ep=memory[{~bank,rp}];
 if(we)memory[{bank,wi}]=wd;
 #1;if(check_enable)begin
  if(cur[6:0]!==ec||prev[6:0]!==ep)$fatal(1,"BRAM synchronous read mismatch cur=%h expected=%h prev=%h expected=%h",cur,ec,prev,ep);
  checks=checks+1;
 end
end
initial begin
 #100;
 // Initialize both banks before checking; RTL separately gates uninitialized data.
 for(i=0;i<128;i=i+1)begin @(negedge clk);we=1;bank=i>>6;wi=i;wd=$random;end
 @(negedge clk);check_enable=1;bank=0;
 for(rounds=0;rounds<4096;rounds=rounds+1)begin
  @(negedge clk);bank=rounds[7];we=rounds[1:0]!=0;wi=$random;ri=$random;rp=ri==0?0:ri-1'b1;wd=$random;
 end
 @(negedge clk);check_enable=0;
 $display("PASS vendor resource BRAM: %0d two-port synchronous reads, bank isolation and swaps",checks);$finish;
end
initial begin #100000;$fatal(1,"BRAM watchdog");end
endmodule
