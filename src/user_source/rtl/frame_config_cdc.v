`timescale 1ns/1ps
// 带应答的稳定总线快照；源端忙时保留最新值，下一个请求自动补发。
module frame_config_cdc #(parameter WIDTH=64,parameter [WIDTH-1:0] RESET_VALUE=0)(
    input wire src_clk,src_rst_n,input wire [WIDTH-1:0] src_data,
    input wire dst_clk,dst_rst_n,frame_start,output reg [WIDTH-1:0] dst_data);
    reg [WIDTH-1:0] held;
    reg request,ack;
    (* async_reg="true" *) reg ack_sync1,ack_sync2,req_sync1,req_sync2;
    always @(posedge src_clk or negedge src_rst_n)
        if(!src_rst_n) begin held<=RESET_VALUE;request<=0;ack_sync1<=0;ack_sync2<=0;end
        else begin
            ack_sync1<=ack;ack_sync2<=ack_sync1;
            if(request==ack_sync2 && src_data!=held) begin held<=src_data;request<=~request;end
        end
    always @(posedge dst_clk or negedge dst_rst_n)
        if(!dst_rst_n) begin req_sync1<=0;req_sync2<=0;ack<=0;dst_data<=RESET_VALUE;end
        else begin
            req_sync1<=request;req_sync2<=req_sync1;
            if(frame_start && req_sync2!=ack) begin dst_data<=held;ack<=req_sync2;end
        end
endmodule
