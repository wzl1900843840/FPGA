`timescale 1ns/1ps
module tb_ui_command;
reg s=0,d=0,r=0,valid=0,fs=0,ready=0;always #5 s=~s;always #7 d=~d;
reg [2:0] command=1;reg [1:0] sp=0,dp=0;wire busy,out;wire [2:0] op;integer count=0;
ui_command_cdc u(s,r,valid,command,sp,busy,d,r,fs,ready,dp,out,op);
always @(negedge d)if(out)count=count+1;
task frame;begin @(negedge d);fs=1;@(negedge d);fs=0;repeat(4)@(negedge d);end endtask
task send;input[2:0]c;begin @(negedge s);command=c;valid=1;@(negedge s);valid=0;repeat(5)@(negedge d);end endtask
initial begin
 #18;r=1;send(3);frame;if(!busy || count!=0)$fatal(1,"queued action lost");
 ready=1;frame;repeat(5)@(negedge s);if(busy || count!=1 || op!=3)$fatal(1,"dequeue ack");
 ready=0;send(1);dp=2;frame;repeat(5)@(negedge s);if(busy || count!=1)$fatal(1,"obsolete page replay");
 sp=2;send(4);frame;repeat(5)@(negedge s);if(busy || count!=1)$fatal(1,"menu executed");
 sp=0;dp=0;ready=1;send(2);frame;if(count!=2 || op!=2)$fatal(1,"second action");
 $display("PASS UI command: async clocks, backpressure, page cancellation, ack and rearm");$finish;
end
initial begin #10000;$fatal(1,"mailbox timeout");end
endmodule
