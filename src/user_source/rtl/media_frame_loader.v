`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 帧装载器：把解码出来的像素流按正确顺序写进 SDRAM 的对应图区
//
// 上游给什么：pixel_valid + pixel_rgb（每个有效像素一个24位值），
//             外加 frame_commit（这一帧解码完成）和 decode_error。
// 本模块做什么：
//   1) 用小FIFO(512字)缓冲像素，攒够 BURST_SIZE(128) 字就向SDRAM发一笔连续写，
//      避免上游解码节奏抖动直接打到SDRAM控制器上；
//   2) 把"像素序号"换算成 SDRAM 字地址（见下面 write_row/write_column）；
//   3) 帧结束时核对收到/写出的像素数是否等于 IMAGE_WORDS，
//      只有数量和提交都正确才把 image_complete[图号] 置1；
//   4) 任何一步出错就记 memory_error，并且默认放弃这一帧（该图保持"未完成"，
//      显示侧就不会用它，避免显示半张图）。
//
// 行序处理：BMP 默认是底行在前的（bottom-up）。source_top_down 表示上游是否已
// 把行序翻好；没翻的话这里用 (479-write_row) 把行倒过来写，
// 保证 SDRAM 里永远是"第0行在最前面"，读出来显示就是正的。
//
// 错误码：41=没开始就收到像素，42=FIFO被写满，43=像素数超了，
//        44=解码报错，45=帧不完整，46=写SDRAM长时间卡住（超时）。
// -----------------------------------------------------------------------------
module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer DRAIN_ON_ERROR = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    input  wire [2:0]            image_index,
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input wire source_top_down,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    output wire                  load_busy,
    output reg                   load_done,
    output reg  [4:0]            image_complete,
    output reg  [7:0]            memory_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output reg  [31:0]           app_wr_data
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    // 一帧的像素数：640×480=307200；非标准尺寸时退化成顺序地址
    localparam [ADDR_WIDTH-1:0] BANK0_BASE = 0;
    localparam [ADDR_WIDTH-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_WIDTH-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_WIDTH-1:0] BANK3_BASE = IMAGE_WORDS * 3;
    localparam [ADDR_WIDTH-1:0] BANK4_BASE = IMAGE_WORDS * 4;

    reg [9:0] write_column;
    reg [8:0] write_row;
    reg active;
    reg [2:0] active_image;
    reg commit_seen;
    reg [31:0] pixels_received;
    reg [31:0] pixels_written;
    reg [31:0] stall_count;
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    reg [7:0] pending_error;
    wire pop_allowed;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;

    assign load_busy = active;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    // 满足以下条件才允许开一笔突发：在装载中、没有待处理错误、控制器就绪、
    // 当前没有突发在跑、FIFO里有数据，而且要么攒满一整笔，要么本帧已提交(收尾)
    assign start_burst = active && pending_error==0 && controller_init_done && !burst_active &&
                         fifo_count != 0 &&
                         (fifo_count >= EFFECTIVE_BURST || commit_seen);
    assign next_burst_words = (fifo_count >= EFFECTIVE_BURST) ?
                              EFFECTIVE_BURST : fifo_count;
    // 突发进行中就可以逐字往外搬（不用再等凑满）
    assign pop_allowed = active && controller_init_done && burst_active &&
                         fifo_count != 0;
    // 允许写入FIFO：只要还有空位，或者这一拍正好在往外搬（腾出位置）
    assign push_allowed = active && pending_error==0 && pixel_valid &&
                          (fifo_count < FIFO_DEPTH || pop_allowed);

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = BANK0_BASE;
                3'd1: bank_base = BANK1_BASE;
                3'd2: bank_base = BANK2_BASE;
                3'd3: bank_base = BANK3_BASE;
                default: bank_base = BANK4_BASE;
            endcase
        end
    endfunction

    // 出错处理：DRAIN_ON_ERROR=1 时把当前这笔突发写完再停，
    // 避免把半个块留在下游CDC里（重试/跳过时状态更干净）。
    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            if(DRAIN_ON_ERROR && burst_active) begin
                // The burst was admitted only with all its words buffered.
                // Finish that burst so the downstream CDC never holds a
                // partial block across retry/skip. Failed banks stay private.
                pending_error <= code;
            end else begin
                active <= 1'b0;
                burst_active <= 1'b0;
                burst_remaining <= 0;
                pending_error <= 0;
                load_done <= 1'b1;
            end
        end
    endtask

    // 独立同步读写过程，无异步清零数据寄存器，确保推断双口BRAM。
    wire transfer_ok=decode_error==0 && !(pixel_valid && pixels_received>=IMAGE_WORDS) && !(pixel_valid && !push_allowed);
    always @(posedge clk) begin
        if(push_allowed && transfer_ok) fifo_mem[wr_ptr]<={8'h00,pixel_rgb};
        if(pop_allowed && (transfer_ok || pending_error!=0)) app_wr_data<=fifo_mem[rd_ptr];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_image <= 3'd0;
            commit_seen <= 1'b0;
            pixels_received <= 32'd0;
            pixels_written <= 32'd0;
                write_column<=0;write_row<=0;
            stall_count <= 32'd0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            burst_active <= 1'b0;
            burst_remaining <= 0;
            pending_error <= 0;
            load_done <= 1'b0;
            image_complete <= 5'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;

        end else begin
            load_done <= 1'b0;
            app_wr_en <= 1'b0;

            if (load_start && !active) begin
                active <= 1'b1;
                active_image <= image_index;
                commit_seen <= 1'b0;
                pixels_received <= 32'd0;
                pixels_written <= 32'd0;
                write_column<=0;write_row<=0;
                stall_count <= 32'd0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                burst_active <= 1'b0;
                burst_remaining <= 0;
                pending_error <= 0;
                memory_error <= ERR_NONE;
                case (image_index)
                    3'd0: image_complete[0] <= 1'b0;
                    3'd1: image_complete[1] <= 1'b0;
                    3'd2: image_complete[2] <= 1'b0;
                    3'd3: image_complete[3] <= 1'b0;
                    default: image_complete[4] <= 1'b0;
                endcase
            end

            if (active) begin
                if (pending_error != 0) begin
                    // 收尾模式：只把已攒的数据写完，然后真正结束这一帧
                    if(pop_allowed) begin
                        app_wr_en<=1;
                        app_wr_addr<=bank_base(active_image)+(IMAGE_WORDS==307200 ?
                            (source_top_down ? write_row : 479-write_row)*640+write_column :
                            pixels_written[ADDR_WIDTH-1:0]);
                        app_wr_mask<=0;rd_ptr<=rd_ptr+1'b1;
                        fifo_count<=fifo_count-1'b1;pixels_written<=pixels_written+1'b1;
                        if(write_column==639) begin write_column<=0;write_row<=write_row+1'b1;end
                        else write_column<=write_column+1'b1;
                        burst_remaining<=burst_remaining-1'b1;
                        if(burst_remaining==1) burst_active<=0;
                    end
                    if(!burst_active) fail_load(pending_error);
                end else if (decode_error != 0) begin
                    fail_load(ERR_DECODE);
                end else if (pixel_valid && pixels_received >= IMAGE_WORDS) begin
                    fail_load(ERR_PIXEL_COUNT);          // 像素多了，帧尺寸不对
                end else if (pixel_valid && !push_allowed) begin
                    fail_load(ERR_FIFO_OVERFLOW);        // 写不进去，说明下游没跟上
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (push_allowed) begin

                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                    end

                    if (pop_allowed) begin
                        // 写地址 = 图区基址 + 行×640 + 列；行序按BMP朝向决定是否倒排
                        app_wr_en <= 1'b1;
                        app_wr_addr <= bank_base(active_image) +
                            (IMAGE_WORDS==307200 ?
                            (source_top_down ? write_row : 479-write_row)*640 + write_column :
                            pixels_written[ADDR_WIDTH-1:0]);
                        if(write_column==639) begin write_column<=0;write_row<=write_row+1'b1;end
                        else write_column<=write_column+1'b1;

                        app_wr_mask <= 4'b0000;
                        rd_ptr <= rd_ptr + 1'b1;
                        pixels_written <= pixels_written + 1'b1;
                        stall_count <= 32'd0;
                        if (burst_remaining == 1) begin
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (fifo_count != 0 &&
                                 (commit_seen || fifo_count >= EFFECTIVE_BURST)) begin
                        // 有数据要写但突发没开起来：数到超时就是写SDRAM卡死了
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 32'd0;
                    end

                    case ({push_allowed, pop_allowed})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase

                    if (frame_commit)
                        commit_seen <= 1'b1;   // 上游声明本帧解码结束

                    // 收尾判定：已提交、FIFO空、没有正在搬的字、也没有突发在跑
                    if (commit_seen && fifo_count == 0 && !pop_allowed &&
                        !burst_active) begin
                        if (pixels_received != IMAGE_WORDS || pixels_written != IMAGE_WORDS) begin
                            fail_load(ERR_SHORT_FRAME);   // 数量对不上，不发布这一帧
                        end else begin
                            // 数量正确才置"该图可用"，显示侧只认这个完成位
                            case (active_image)
                                3'd0: image_complete[0] <= 1'b1;
                                3'd1: image_complete[1] <= 1'b1;
                                3'd2: image_complete[2] <= 1'b1;
                                3'd3: image_complete[3] <= 1'b1;
                                default: image_complete[4] <= 1'b1;
                            endcase
                            active <= 1'b0;
                            load_done <= 1'b1;
                        end
                    end
                end
            end else if (pixel_valid) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
