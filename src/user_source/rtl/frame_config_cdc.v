`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 多位参数的跨时钟域"帧边界提交"器（工程里所有多位参数都走它）
//
// 为什么不能直接打两拍：多位总线逐位同步时各位到达拍数可能不同，目的域会读到
// 一半新一半旧的组合值（撕裂）。这里改成"保持总线 + 请求/应答"：
//   1) 源域把 src_data 寄存进 held，数据保持不变；
//   2) 源域用 request 翻转一次表示"有新值"；
//   3) 目的域把 request 打两拍，只在 frame_start（帧边界）那一拍把 held 整份
//      拷进 dst_data——所以画面中间参数不会变，一帧之内看到的永远是同一份快照；
//   4) 目的域把 ack 翻回源域，源域确认后才允许下一次更新。
//
// 源端忙时（request != 已同步回的 ack）新值不会丢：src_data 变化会被 held 记住，
// 等 ack 回来后自动补发。所以调用方可以随便改输入，模块自己保证最终一致。
// RESET_VALUE 决定复位后的默认参数（例如亮度255/对比度128/周期5000ms）。
// -----------------------------------------------------------------------------
module frame_config_cdc #(parameter WIDTH=64,parameter [WIDTH-1:0] RESET_VALUE=0)(
    input wire src_clk,src_rst_n,input wire [WIDTH-1:0] src_data,
    input wire dst_clk,dst_rst_n,frame_start,output reg [WIDTH-1:0] dst_data);
    reg [WIDTH-1:0] held;      // 源域稳定副本：跨域搬的是它，不是变化的 src_data
    reg request,ack;           // request 源→目的"有新值"，ack 目的→源"已收下"
    (* async_reg="true" *) reg ack_sync1,ack_sync2,req_sync1,req_sync2;
    always @(posedge src_clk or negedge src_rst_n)
        if(!src_rst_n) begin held<=RESET_VALUE;request<=0;ack_sync1<=0;ack_sync2<=0;end
        else begin
            ack_sync1<=ack;ack_sync2<=ack_sync1;                 // 应答打两拍回到源域
            // 上一次已被目的域收下，且数据确实变了，才发起新一次传递
            if(request==ack_sync2 && src_data!=held) begin held<=src_data;request<=~request;end
        end
    always @(posedge dst_clk or negedge dst_rst_n)
        if(!dst_rst_n) begin req_sync1<=0;req_sync2<=0;ack<=0;dst_data<=RESET_VALUE;end
        else begin
            req_sync1<=request;req_sync2<=req_sync1;             // 请求打两拍进入目的域
            // 只在帧边界整份提交，并回一个 ack 告诉源域可以发下一份
            if(frame_start && req_sync2!=ack) begin dst_data<=held;ack<=req_sync2;end
        end
endmodule
