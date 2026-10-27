`timescale 1ns/1ps
module tb_fade;
reg clk=0,rst=0,request=0,fs=0,commit=0;reg[1:0]idx=0;always #5 clk=~clk;
wire next,busy,active,wipe;wire[7:0]alpha;wire[4:0]ramp;wire[1:0]kind;
video_fade_transition #(.FADE_FRAMES(4)) d(clk,rst,request,next,busy,clk,rst,1'b1,fs,commit,idx,alpha,active,wipe,ramp,kind,1'b0);
integer requests=0,i,k;reg pending=0;
always @(posedge clk)if(next)begin if(alpha!=0)$fatal(1,"switch before black");requests=requests+1;pending=1;end
task frame;begin
repeat(12)@(negedge clk);fs=1;if(pending)begin commit=1;pending=0;end
@(negedge clk);fs=0;commit=0;repeat(12)@(negedge clk);
end endtask
initial begin
#21;rst=1;@(negedge clk);request=1;@(negedge clk);request=0;
for(i=0;i<15;i=i+1)frame;
if(requests!=1||alpha!=255||busy)$fatal(1,"manual fade did not finish");
for(k=0;k<4;k=k+1)begin
@(negedge clk);idx=k;commit=1;@(negedge clk);commit=0;
if(!wipe||kind!=k||ramp!=0)$fatal(1,"wipe kind");
for(i=0;i<5;i=i+1)frame;
if(wipe||alpha!=255||busy)$fatal(1,"wipe did not finish");
end
$display("PASS fade: switch only at black, full recovery, all four wipe kinds");$finish;
end
endmodule
