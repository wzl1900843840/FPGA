`timescale 1ns/1ps
module demo_switch_filter #(parameter integer STABLE_MS=20)(
 input wire clk,rst_n,tick_ms,input wire [3:0] raw,output reg [3:0] stable);
 (* async_reg="true" *)reg [3:0] sw_sync1,sw_sync2;
 reg [7:0] count[0:3];integer i;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin sw_sync1<=0;sw_sync2<=0;stable<=0;for(i=0;i<4;i=i+1)count[i]<=0;end
 else begin
  sw_sync1<=raw;sw_sync2<=sw_sync1;
  if(tick_ms)for(i=0;i<4;i=i+1)begin
   if(sw_sync2[i]==stable[i])count[i]<=0;
   else if(count[i]>=STABLE_MS-1)begin stable[i]<=sw_sync2[i];count[i]<=0;end
   else count[i]<=count[i]+1'b1;
  end
 end
endmodule
