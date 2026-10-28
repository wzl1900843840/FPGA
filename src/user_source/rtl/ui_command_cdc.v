`timescale 1ns/1ps
// One outstanding action, acknowledged only when the destination consumes it
// at frame_start. held includes the page version; obsolete actions are consumed
// without execution when a page/alert changes.
module ui_command_cdc(input wire src_clk,src_rst_n,src_valid,
 input wire [2:0] src_command,input wire [1:0] src_page,output wire src_busy,
 input wire dst_clk,dst_rst_n,frame_start,dst_ready,input wire [1:0] dst_page,
 output reg dst_valid,output reg [2:0] dst_command);
 reg [4:0] held;reg request,ack;
 (* async_reg="true" *)reg ack_sync1,ack_sync2,req_sync1,req_sync2;
 assign src_busy=request!=ack_sync2;
 always @(posedge src_clk or negedge src_rst_n)
 if(!src_rst_n)begin held<=0;request<=0;ack_sync1<=0;ack_sync2<=0;end
 else begin
  ack_sync1<=ack;ack_sync2<=ack_sync1;
  if(src_valid && !src_busy)begin held<={src_page,src_command};request<=~request;end
 end
 always @(posedge dst_clk or negedge dst_rst_n)
 if(!dst_rst_n)begin req_sync1<=0;req_sync2<=0;ack<=0;dst_valid<=0;dst_command<=0;end
 else begin
  req_sync1<=request;req_sync2<=req_sync1;dst_valid<=0;
  if(frame_start && req_sync2!=ack && (held[4:3]!=dst_page || dst_page[1] || dst_ready))begin
   ack<=req_sync2;dst_command<=held[2:0];
   dst_valid<=held[4:3]==dst_page && !dst_page[1];
  end
 end
endmodule
