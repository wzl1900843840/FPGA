`timescale 1ns/1ps
module tb_seg7;
reg clk=0;always #5 clk=~clk;
reg rst=0,enable=1,pic=0,vol=0,prd=0;
reg [1:0] media=0;
reg [7:0] volume=255;
reg [5:0] period=30;
wire [7:0] seg,dig;
reg [7:0] observed[0:7];
integer i,n,idx;
seg7_panel #(.SCAN_STEP_CYCLES(2),.PAGE_PERIOD_CYCLES(10000),.HOLD_CYCLES(10000))
 dut(clk,rst,enable,media,volume,period,pic,vol,prd,seg,dig);
task capture;begin
 for(n=0;n<32;n=n+1)begin
  @(negedge clk);
  for(idx=0;idx<8;idx=idx+1)if(dig==~(8'b1<<idx))observed[idx]=~seg;
 end
end endtask
task expect_digit;input integer select;input [7:0] glyph;begin
 if(observed[select]!==glyph)$fatal(1,"physical digit %0d got%h expected%h",select,observed[select],glyph);
end endtask
initial begin
 #12;rst=1;
 for(i=0;i<4;i=i+1)begin
  media=i;capture;
  expect_digit(4,8'h73);expect_digit(5,8'h06);expect_digit(6,8'h39);
  case(i)
   0:expect_digit(7,8'h06);1:expect_digit(7,8'h5b);
   2:expect_digit(7,8'h4f);3:expect_digit(7,8'h66);
  endcase
  expect_digit(0,0);expect_digit(1,0);expect_digit(2,0);expect_digit(3,0);
 end
 vol=1;@(negedge clk);vol=0;capture;
 expect_digit(0,8'h3e);expect_digit(1,8'h3f);expect_digit(2,8'h38);expect_digit(3,0);
 expect_digit(4,0);expect_digit(5,8'h5b);expect_digit(6,8'h6d);expect_digit(7,8'h6d);
 volume=0;capture;
 expect_digit(0,8'h3e);expect_digit(1,8'h3f);expect_digit(2,8'h38);expect_digit(3,0);
 expect_digit(4,0);expect_digit(5,8'h3f);expect_digit(6,8'h3f);expect_digit(7,8'h3f);
 prd=1;@(negedge clk);prd=0;capture;
 expect_digit(0,8'h6d);expect_digit(1,8'h79);expect_digit(2,8'h39);expect_digit(3,0);
 expect_digit(4,0);expect_digit(5,0);expect_digit(6,8'h4f);expect_digit(7,8'h3f);
 period=55;capture;
 expect_digit(0,8'h6d);expect_digit(1,8'h79);expect_digit(2,8'h39);expect_digit(3,0);
 expect_digit(4,0);expect_digit(5,0);expect_digit(6,8'h6d);expect_digit(7,8'h6d);
 enable=0;@(negedge clk);if(dig!=255 || seg!=255)$fatal(1,"disabled panel");
 $display("PASS seg7: physical left/right blocks, PIC1..PIC4, VOL 000/255, SEC 30/55, disabled panel");
 $finish;
end
endmodule
