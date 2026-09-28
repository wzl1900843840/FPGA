`timescale 1ns/1ps
module tb_pll_clocks;
reg clk=0,reset=1;
always #10 clk=~clk;
wire c0,c1,c2,c3,c4,locked;
sys_pll_promax_40 dut(clk,reset,c0,c1,c2,c3,c4,locked);
real t1=0,t2=0,t3=0,t4=0;
integer n1=0,n2=0,n3=0,n4=0;
always @(posedge c1) if(locked) begin if(n1==10)$display("mem period=%f ns",$realtime-t1);t1=$realtime;n1=n1+1;end
always @(posedge c2) if(locked) begin if(n2==10)$display("shift period=%f ns; offset since mem=%f ns",$realtime-t2,$realtime-t1);t2=$realtime;n2=n2+1;end
always @(posedge c3) if(locked) begin if(n3==10)$display("pixel period=%f ns",$realtime-t3);t3=$realtime;n3=n3+1;end
always @(posedge c4) if(locked) begin if(n4==10)$display("serial period=%f ns",$realtime-t4);t4=$realtime;n4=n4+1;end
initial begin #200 reset=0;#200000;$display("locked=%b counts %d %d %d %d",locked,n1,n2,n3,n4);$finish;end
endmodule
