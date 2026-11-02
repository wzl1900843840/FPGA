`timescale 1ns/1ps
module tb_recovery;
reg clk=0,r=0,tick=0,manual=0,fault=0,boot=1,ack=0;always #5 clk=~clk;
wire reset_n,display,busy,failed;wire [7:0] retries;
media_recovery_manager #(.RESET_MS(2),.STARTUP_TIMEOUT_MS(10)) d(clk,r,tick,manual,fault,boot,ack,reset_n,display,busy,failed,retries);
task ms;input integer n;integer i;begin for(i=0;i<n;i=i+1)begin @(negedge clk);tick=1;@(negedge clk);tick=0;end end endtask
initial begin
 #12;r=1;ms(3);fault=1;ms(1);fault=0;ms(3);
 if(!display || !reset_n || !busy)$fatal(1,"reset before fallback ack");
 ack=1;ms(1);if(reset_n)$fatal(1,"reset missing");boot=0;ms(3);if(!reset_n || retries!=1)$fatal(1,"reset duration");
 boot=1;ms(2);ack=0;ms(2);if(display || busy)$fatal(1,"recovery completion");
 fault=1;ms(1);fault=0;ack=1;ms(3);if(!failed || !reset_n || retries!=1)$fatal(1,"automatic retry bound");
 manual=1;ms(1);manual=0;boot=0;ms(4);if(retries!=2)$fatal(1,"manual retry");
 boot=1;ms(2);ack=0;ms(2);if(busy || failed)$fatal(1,"manual completion");
 fault=1;ms(1);fault=0;ms(102);
 if(!failed || !reset_n || busy || !display)$fatal(1,"missing display ACK caused reset or unbounded wait");
 $display("PASS recovery: fallback ack before reset, bounded retry, STOP/manual rearm, missing-ACK 100ms stop");$finish;
end
initial begin #10000;$fatal(1,"recovery timeout");end
endmodule
