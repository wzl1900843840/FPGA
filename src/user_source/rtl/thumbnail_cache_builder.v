`timescale 1ns/1ps
// 四原图 bank 保持不变，剩余 SDRAM 中预合成一张 640x480 缩略图页。
// 每次读取源图一行的连续 640 字，抽取 x=0,4,...636，组成两个160x120窗口。
// 所有外部访问均为128字连续 burst；共享模式下由仲裁器调度后台构建。
//
// -----------------------------------------------------------------------------
// 缩略图缓存构建器（40MHz 内存域，只在启动期跑一次）
//
// 目标：在 SDRAM 第5页(地址 FRAME_WORDS*4 起)预合成一张 640×480 的"缩略图页"，
//       页里左上 320×240 区域按 2×2 排了四格 160×120 的缩小图，
//       其余区域清成黑色。这样缩略图显示不需要实时缩放，直接当普通图读出来即可。
//
// 缩小方法（4:1 抽样）：读源图某一行的连续 640 个字（一个 burst 行），
//       只取 x = 0,4,8,...636 这些列，两列拼成一个 32 位字写进行缓冲；
//       每个 160×120 窗口对应源图的一块 640×480 区域（源坐标 = 局部坐标 × 4）。
//       四格分别来自四张原图（bank = {上下半, 左右半}）。
//
// 状态机：CLEAR(把本行缓冲清零) → PREPARE(决定这一行取哪张图/哪一半)
//        → READ(发 128 字一笔的突发读) → DRAIN(等读返回凑够一行)
//        → WRITE(把行缓冲写回缩略图页) → GAP(等控制器排空) → FINISH
//        y<120 或 y>=360 的行不在缩略图区内，直接清黑写过去（见 PREPARE 的判断）。
//
// 其他细节：
//   - 源图若未完整校验(image_complete=0)，那一半窗口就留黑，不冒险读坏数据；
//   - burst_request 只在每 128 字的边界发一次，配合 burst_grant 交给仲裁器；
//   - DRAIN 里有 watchdog，读返回迟迟不来就报错误码 65 并结束，避免死等。
// -----------------------------------------------------------------------------
module thumbnail_cache_builder #(
    parameter integer FRAME_WORDS=307200,
    parameter integer WAIT_CYCLES=256,
    parameter integer SHARED_MEMORY=0
)(
    input wire clk,rst_n,start,
    input wire [3:0] image_complete,
    output wire busy,
    output reg done,
    output reg [7:0] error,
    output reg app_rd_en,
    output reg [20:0] app_rd_addr,
    input wire rd_valid,
    input wire [31:0] rd_data,
    output reg app_wr_en,
    output reg [20:0] app_wr_addr,
    output reg [31:0] app_wr_data,
    input wire controller_busy,refresh_active,
    input wire burst_grant,
    output wire burst_request,burst_write
);
    reg [31:0] row [0:639] /* fehdl force_ram=1, ram_style="bram" */;   // 行缓冲：一行640个32位字
    reg [3:0] state;
    reg [9:0] x,received;
    reg [8:0] y;
    reg side;                       // 0=左半格，1=右半格
    reg [8:0] gap;                  // burst 之间的等待间隔
    reg [19:0] watchdog;            // DRAIN 阶段等读返回的超时计数
    // Match thumbnail_layout: a 320x240 grid centered in the 640x480 cache.
    localparam integer ORIGIN_X=160, ORIGIN_Y=120;   // 缩略图区在页中的左上角
    // bank = {上下半, 左右半}：决定这一行取自哪张原图
    wire [1:0] bank={y>=ORIGIN_Y+120,side};
    // 源图起始地址：源行 = (缩略图行 - 120) × 4（4:1 抽样）
    wire [20:0] source_base=bank*FRAME_WORDS + ((y>=ORIGIN_Y+120?y-ORIGIN_Y-120:y-ORIGIN_Y)*4)*640;
    localparam IDLE=0,CLEAR=1,PREPARE=2,READ=3,DRAIN=4,WRITE=5,GAP=6,FINISH=7;
    assign busy=state!=IDLE;
    assign burst_write=state==WRITE;
    // 每 128 字申请一次突发授权，和 128 字连续访问的粒度对齐
    assign burst_request=(state==READ || state==WRITE) && x[6:0]==0 && gap==0;
    // 什么时候写行缓冲：清零阶段按 x 写0；读阶段每收到4个返回字抽1个存起来
    wire row_write=state==CLEAR || ((state==READ || state==DRAIN) && rd_valid && received<640 && received[1:0]==0);
    wire [9:0] row_address=state==CLEAR ? x : ORIGIN_X+(side?160:0)+(received>>2);
    always @(posedge clk) if(state==WRITE) app_wr_data<=row[x];
    always @(posedge clk) if(row_write) row[row_address]<=state==CLEAR ? 32'd0:rd_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;done<=0;error<=0;x<=0;y<=0;side<=0;received<=0;gap<=0;watchdog<=0;
            app_rd_en<=0;app_rd_addr<=0;app_wr_en<=0;app_wr_addr<=0;
        end else begin
            done<=0;app_rd_en<=0;app_wr_en<=0;
            case(state)
            IDLE: if(start) begin state<=CLEAR;x<=0;y<=0;error<=0;end
            CLEAR: begin

                if(x==639) begin x<=0;side<=0;state<=PREPARE;end else x<=x+1'b1;
            end
            PREPARE: begin
                x<=0;received<=0;watchdog<=0;gap<=0;
                // 不在缩略图区内的行：不用读源图，直接写黑
                if(y<ORIGIN_Y || y>=ORIGIN_Y+240) state<=WRITE;
                // 对应源图还没校验完整：先留黑，先做右半格再结束这一行
                else if(!image_complete[bank]) begin
                    if(side) state<=WRITE;else side<=1;
                end else state<=READ;
            end
            READ: begin
                // 每128字后留出控制器排队间隙，返回数据与发出请求分别计数。
                if(gap!=0) gap<=gap-1'b1;
                else if(x[6:0]!=0 || (!controller_busy && !refresh_active && (!SHARED_MEMORY || burst_grant))) begin
                    app_rd_en<=1;app_rd_addr<=source_base+x;
                    if(x==639) state<=DRAIN;
                    else begin x<=x+1'b1;if(x[6:0]==127) gap<=16;end
                end
            end
            DRAIN: begin
                // 等这一行的读返回凑满 640 个；超时报错退出，避免死等
                if(received==640) begin
                    if(!side) begin side<=1;state<=PREPARE;end
                    else begin x<=0;gap<=WAIT_CYCLES;state<=GAP;end
                end else if(watchdog==20'hfffff) begin error<=8'h65;state<=FINISH;end
                else watchdog<=watchdog+1'b1;
            end
            WRITE: if(x[6:0]!=0 || (!controller_busy && !refresh_active && (!SHARED_MEMORY || burst_grant))) begin
                // 把行缓冲写回缩略图页：目标地址 = 第5页 + 页内行偏移 + 列
                app_wr_en<=1;app_wr_addr<=FRAME_WORDS*4+y*640+x;
                if(x==639) begin x<=0;gap<=WAIT_CYCLES;state<=FINISH;end
                else begin
                    x<=x+1'b1;
                    if(x[6:0]==127) begin gap<=16;state<=GAP;end
                end
            end
            GAP: if(gap!=0) gap<=gap-1'b1;else state<=WRITE;
            FINISH: if(gap!=0) gap<=gap-1'b1;
                else if(y==479 || error!=0) begin done<=1;state<=IDLE;end
                else begin y<=y+1'b1;x<=0;state<=CLEAR;end
            default: state<=IDLE;
            endcase
            if((state==READ || state==DRAIN) && rd_valid && received<640) begin

                received<=received+1'b1;
            end
        end
    end
endmodule
