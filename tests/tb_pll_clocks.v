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
initial begin #200 reset=0;#200000;
 if(!locked || n1<100 || n2<100 || n3<100 || n4<100)$fatal(1,"PLL did not lock");
 $display("locked=%b counts %d %d %d %d",locked,n1,n2,n3,n4);
 $display("PASS PLL: 40/40/25/125 MHz and 10 ns SDRAM shift");$finish;end
real m0=0,m1=0,m2=0,m3=0;
always @(posedge c1) if(locked) begin
 if(m0>0 && ($realtime-m0<24.99 || $realtime-m0>25.01))$fatal(1,"memory period");m0=$realtime;end
always @(posedge c2) if(locked) begin
 if(m1>0 && ($realtime-m1<24.99 || $realtime-m1>25.01))$fatal(1,"shift period");
 if(m0>0 && ($realtime-m0<9.99 || $realtime-m0>10.01))$fatal(1,"SDRAM phase");m1=$realtime;end
always @(posedge c3) if(locked) begin
 if(m2>0 && ($realtime-m2<39.99 || $realtime-m2>40.01))$fatal(1,"pixel period");m2=$realtime;end
always @(posedge c4) if(locked) begin
 if(m3>0 && ($realtime-m3<7.99 || $realtime-m3>8.01))$fatal(1,"serial period");m3=$realtime;end
endmodule
