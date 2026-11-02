`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// SDRAM 三路访问仲裁（40MHz 内存域）
//
// 谁在抢 SDRAM：
//   VIDEO(1)：视频读取，显示要用，最不能停；
//   WRITE(2)：系统域写入CDC搬过来的图片数据，可以慢，但不能丢；
//   CACHE(3)：启动期缩略图缓存的读+写，只在启动阶段忙。
//
// 仲裁规则（三句话）：
//   1) 一次只让一路用，而且一次用满一整笔 BURST_SIZE=128 字，中途不切换——
//      这样突发读的效率最高，也不会把某一笔事务切成两半；
//   2) 优先级：视频"饥饿"(video_urgent，FIFO 水位过低) 时最高；否则写入和缓存
//      先来先得，视频最后兜底；即显示优先，后台任务用显示的剩余带宽；
//   3) 控制器忙或正在刷新时谁都不发请求，等总线空出来再选。
//
// 一笔事务结束不是立刻放总线：要再等 DRAIN_CYCLES 拍（retiring/drain），
// 让最后一个写数据或读返回真正落地，避免下一路刚接管就撞上残留事务。
// video_return/cache_return 用来把读返回数据"认领"给发起方，
// write_drained 表示写入通路确实空了（顶层启动状态机用它判断写入是否排空）。
// -----------------------------------------------------------------------------
// One complete 128-word transaction owns the vendor interface until its
// returns/drain finish. The display wins below its FIFO watermark; background
// writes and thumbnail work use the buffered display's spare bandwidth.
module media_sdram_arbiter #(
    parameter integer BURST_SIZE = 128,
    parameter integer DRAIN_CYCLES = 16,
    parameter integer STALL_LIMIT = 4000000
) (
    input wire clk, rst_n,
    input wire controller_busy, refresh_active,
    input wire video_request, video_urgent,
    input wire write_request, cache_request, cache_write,
    input wire app_read, app_write, rd_valid,
    output wire video_grant, write_grant, cache_grant,
    output wire [1:0] owner,
    output wire video_return, cache_return,
    output wire write_drained,output reg fault,
    output reg [21:0] diagnostic_max_wait,
    output reg [21:0] diagnostic_write_wait,
    output reg [21:0] diagnostic_cache_wait
);
    localparam NONE=2'd0, VIDEO=2'd1, WRITE=2'd2, CACHE=2'd3;
    reg [1:0] active_owner;        // 当前占用总线的路（NONE=空闲）
    reg active_write, retiring;    // 本笔事务是写还是读；retiring=事务已完成、正在排空
    reg [$clog2(BURST_SIZE)-1:0] commands, returns;   // 已发出的命令数 / 已收到的读返回数
    reg [$clog2(DRAIN_CYCLES+1)-1:0] drain;           // 排空计数
    reg [1:0] selected;
    reg [21:0] stall_count,wait_count,write_wait_count,cache_wait_count;
    reg [1:0] last_background;
    always @(posedge clk or negedge rst_n)
    if(!rst_n)begin
        fault<=0;stall_count<=0;wait_count<=0;write_wait_count<=0;cache_wait_count<=0;
        diagnostic_max_wait<=0;diagnostic_write_wait<=0;diagnostic_cache_wait<=0;
    end
    else begin
        if((active_owner!=NONE && !app_read && !app_write && !rd_valid &&
            (!retiring || controller_busy || refresh_active)) ||
           (active_owner==NONE && selected==NONE && (video_request || write_request || cache_request)))begin
            if(stall_count>=STALL_LIMIT-1)fault<=1;else stall_count<=stall_count+1'b1;
        end else stall_count<=0;
        if(video_request && !video_grant)begin
            if(wait_count!=22'h3fffff)wait_count<=wait_count+1'b1;
            if(wait_count>diagnostic_max_wait)diagnostic_max_wait<=wait_count;
        end else wait_count<=0;
        if(write_request && !write_grant)begin
            if(write_wait_count!=22'h3fffff)write_wait_count<=write_wait_count+1'b1;
            if(write_wait_count>diagnostic_write_wait)diagnostic_write_wait<=write_wait_count;
        end else write_wait_count<=0;
        if(cache_request && !cache_grant)begin
            if(cache_wait_count!=22'h3fffff)cache_wait_count<=cache_wait_count+1'b1;
            if(cache_wait_count>diagnostic_cache_wait)diagnostic_cache_wait<=cache_wait_count;
        end else cache_wait_count<=0;
    end
    // 只有总线完全空闲（无占用、控制器不忙、不在刷新）时才产生新的仲裁结果
    always @* begin
        selected=NONE;
        if(active_owner==NONE && !controller_busy && !refresh_active) begin
            // Video low watermark is absolute priority. Background clients
            // alternate when both are ready; an authorized burst is never cut.
            if(video_request && (video_urgent || (!write_request && !cache_request)))
                selected=VIDEO;
            else if(write_request && cache_request)
                selected=last_background==WRITE ? CACHE : WRITE;
            else if(write_request) selected=WRITE;
            else if(cache_request) selected=CACHE;
            else if(video_request) selected=VIDEO;
        end
    end
    assign owner=active_owner==NONE ? selected : active_owner;   // 给顶层做地址/数据多路选择
    assign video_grant=selected==VIDEO;                          // 单拍授权，发起方见到即开始发命令
    assign write_grant=selected==WRITE;
    assign cache_grant=selected==CACHE;
    assign video_return=active_owner==VIDEO && !retiring;        // 读返回归属：这一段属于视频
    assign cache_return=active_owner==CACHE && !active_write && !retiring;
    assign write_drained=active_owner!=WRITE && selected!=WRITE;  // 写入通路已空

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active_owner<=NONE;active_write<=0;retiring<=0;last_background<=CACHE;
            commands<=0;returns<=0;drain<=0;
        end else if(active_owner==NONE) begin
            // 空闲：一旦选中某一路就接管总线，并记住本笔是读还是写
            if(selected!=NONE) begin
                active_owner<=selected;
                if(selected==WRITE || selected==CACHE)last_background<=selected;
                active_write<=selected==WRITE || (selected==CACHE && cache_write);
                // The CDC client presents its first word on the grant edge.
                commands<=app_write ? 1 : 0;   // 写入方在授权那一拍就已经给出第一个字，这里先记1
                returns<=0;retiring<=0;drain<=0;
            end
        end else if(retiring) begin
            // 事务已完成：等控制器和刷新都空下来，再数满 DRAIN_CYCLES 拍才放总线
            if(controller_busy || refresh_active) drain<=0;
            else if(drain==DRAIN_CYCLES-1) begin
                active_owner<=NONE;retiring<=0;drain<=0;
            end else drain<=drain+1'b1;
        end else if(active_write) begin
            // 写事务：数满 BURST_SIZE 个字就进入排空
            if(app_write) begin
                commands<=commands+1'b1;
                if(commands==BURST_SIZE-1) begin retiring<=1;drain<=0;end
            end
        end else begin
            // 读事务：命令先全部发出去，再数读返回；返回数满同样进入排空
            if(app_read) commands<=commands+1'b1;
            if(rd_valid) begin
                returns<=returns+1'b1;
                if(returns==BURST_SIZE-1) begin retiring<=1;drain<=0;end
            end
        end
    end
endmodule
