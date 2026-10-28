`timescale 1ns/1ps
module tb_arbiter_watchdog;
reg clk=0,r=0,cb=0,refresh=0,vr=0,vu=1,wr=0,cr=0,cw=0,ar=0,aw=0,rv=0;
always #5 clk=~clk;
wire vg,wg,cg,vret,cret,drained,fault;wire[1:0]owner;wire[21:0]maxwait;
media_sdram_arbiter #(.BURST_SIZE(4),.DRAIN_CYCLES(3),.STALL_LIMIT(8)) d(
 clk,r,cb,refresh,vr,vu,wr,cr,cw,ar,aw,rv,vg,wg,cg,owner,vret,cret,drained,fault,maxwait);
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task reset;begin r=0;vr=0;wr=0;cr=0;cb=0;refresh=0;ar=0;aw=0;rv=0;cycles(3);r=1;cycles(1);end endtask
integer i;
initial begin
 reset;vr=1;cb=1;cycles(7);if(fault)$fatal(1,"early watchdog");cycles(2);
 if(!fault || maxwait<7)$fatal(1,"blocked request not detected");
 reset;vr=1;cycles(1);vr=0;ar=1;cycles(4);ar=0;rv=1;cycles(4);rv=0;
 refresh=1;cycles(3);if(owner!=1 || fault)$fatal(1,"refresh released owner");
 refresh=0;cycles(4);if(owner!=0 || fault)$fatal(1,"drain failed");
 reset;vr=1;cycles(1);vr=0;cycles(9);
 if(!fault || owner!=1)$fatal(1,"owner lost on stall");
 reset;wr=1;aw=1;cycles(1);wr=0;cycles(3);aw=0;cb=1;cycles(9);
 if(!fault || owner!=2 || drained)$fatal(1,"retiring watchdog released transaction");
 reset;vr=1;cycles(1);vr=0;ar=1;cycles(4);ar=0;
 for(i=0;i<4;i=i+1)begin cycles(5);rv=1;cycles(1);rv=0;end
 cycles(4);if(fault || owner!=0)$fatal(1,"progress incorrectly times out");
 $display("PASS arbiter watchdog: blocked grant, active/retiring stall, refresh drain, delayed progress, sticky owner");$finish;
end
initial begin #20000;$fatal(1,"arbiter watchdog timeout");end
endmodule
