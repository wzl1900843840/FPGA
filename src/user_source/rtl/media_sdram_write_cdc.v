`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 图片写入的跨时钟域搬运（50MHz 系统域 → 40MHz 内存域）
//
// 为什么要"按块"搬：
//   上游（BMP解码）在 50MHz 域每解码一个像素就写一个字，节奏不均匀；
//   下游 SDRAM 控制器希望连续写整块（这里 128 字一笔）效率最高。
//   所以先用 FIFO 把字攒起来，攒满 128 字（或本帧已结束、剩余不足128）才发一笔。
//
// 两块计数器（关键设计）：
//   src_block_gray：源域每写满128字就把"已满块数"加1，并用Gray码发给目的域；
//   dst_block_gray：目的域每写完一笔也加1。
//   两者不相等(block_pending)说明还有攒好的块没搬完 —— 这样目的域不用去数FIFO
//   里有多少字，只看"块计数差"就知道还有没有活干，跨域判断简单可靠。
//   用Gray码是因为它每次只变一位，打两拍同步时不会出现中间态错值。
//
// 为什么要先预取一个字（prefetch）：
//   目的域决定"开始写"和控制器真正能收第一个字之间隔了好几个周期，
//   这段时间里刷新(refresh)可能刚好开始。如果提前几个周期就定了"要发"，
//   等真正发的时候状态已经过期。所以先读出一个字拿在手上，等
//   controller_busy/refresh_active（以及共享总线的 burst_grant）都允许，
//   才把第一个字发出去；剩下的字随后连续发完，保证一笔写不被打断。
//
// 对外接口：src_full 反压上游，src_overflow 表示上游没理反压（数据丢了）；
//           dst_idle 表示这一路彻底空干净（顶层用它判断写入是否排空）；
//           burst_request/grant 是向顶层仲裁器申请总线。
//
// 文件里还包含一个自制的异步FIFO（async_command_fifo）：
//   存储 [地址+mask+数据] 的整条写命令；读写指针各自转Gray码后打两拍过域，
//   空满判断用标准Gray比较法，rd_level 用Gray转二进制相减得到。
// -----------------------------------------------------------------------------
module media_sdram_write_cdc #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_ADDR_WIDTH = 9,
    parameter integer BURST_SIZE = 128,
    parameter integer SHARED_MEMORY = 0
) (
    input  wire                  src_clk,
    input  wire                  src_rst_n,
    input  wire                  src_wr_en,
    input  wire [ADDR_WIDTH-1:0] src_wr_addr,
    input  wire [3:0]            src_wr_mask,
    input  wire [31:0]           src_wr_data,
    output wire                  src_full,
    output reg                   src_overflow,

    input  wire                  dst_clk,
    input  wire                  dst_rst_n,
    output wire                  dst_app_wr_en,
    output wire [ADDR_WIDTH-1:0] dst_app_wr_addr,
    output wire [3:0]            dst_app_wr_mask,
    output wire [31:0]           dst_app_wr_data,
    output wire                  dst_idle,
    input wire                   controller_busy,
    input wire                   refresh_active,
    input wire                   burst_grant,
    output wire                  burst_request
);
    localparam integer COMMAND_WIDTH = ADDR_WIDTH + 36;
    localparam integer BURST_COUNT_WIDTH = $clog2(BURST_SIZE);
    localparam integer BLOCK_PTR_WIDTH =
        FIFO_ADDR_WIDTH - BURST_COUNT_WIDTH + 1;

    wire [COMMAND_WIDTH-1:0] fifo_rd_data;
    wire fifo_rd_valid;
    wire fifo_empty;
    wire fifo_rd_en;
    reg prefetch_pending;
    reg burst_first;
    reg burst_active;
    reg [$clog2(BURST_SIZE+1)-1:0] burst_remaining;
    reg [BURST_COUNT_WIDTH-1:0] src_burst_word_count;
    reg [BLOCK_PTR_WIDTH-1:0] src_block_binary;
    reg [BLOCK_PTR_WIDTH-1:0] src_block_gray;
    reg [BLOCK_PTR_WIDTH-1:0] src_block_gray_sync1;
    reg [BLOCK_PTR_WIDTH-1:0] src_block_gray_sync2;
    reg [BLOCK_PTR_WIDTH-1:0] dst_block_binary;
    reg [BLOCK_PTR_WIDTH-1:0] dst_block_gray;
    wire src_accept = src_wr_en && !src_full;
    wire block_pending = src_block_gray_sync2 != dst_block_gray;   // 还有整块没搬完
    // Prefetch one word, then hold it until the controller can accept the
    // FIRST word. A registered start decision several cycles earlier is stale
    // when refresh begins during FIFO latency. Remaining words stay continuous.
    wire prefetch_request = !burst_active && !prefetch_pending && block_pending;
    assign burst_request=burst_active && burst_first;   // 第一拍才向仲裁器要总线
    // 第一个字要等控制器空闲、不在刷新、并且拿到总线授权；后续字直接连续发
    assign dst_app_wr_en = burst_active &&
        (!burst_first || (!controller_busy && !refresh_active &&
                         (!SHARED_MEMORY || burst_grant)));
    assign fifo_rd_en = prefetch_request || (dst_app_wr_en && burst_remaining > 1);

    async_command_fifo #(
        .DATA_WIDTH(COMMAND_WIDTH),
        .ADDR_WIDTH(FIFO_ADDR_WIDTH)
    ) u_fifo (
        .wr_clk(src_clk), .wr_rst_n(src_rst_n),
        .wr_en(src_wr_en),
        .wr_data({src_wr_addr, src_wr_mask, src_wr_data}),
        .wr_full(src_full),
        .rd_clk(dst_clk), .rd_rst_n(dst_rst_n),
        .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
        .rd_valid(fifo_rd_valid), .rd_empty(fifo_empty),
        .rd_level()
    );

    // 源域：统计已写满的整块数，并转成Gray码发给目的域
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_overflow <= 1'b0;
            src_burst_word_count <= 0;
            src_block_binary <= 0;
            src_block_gray <= 0;
        end else begin
            if (src_wr_en && src_full)
                src_overflow <= 1'b1;
            if (src_accept) begin
                if (src_burst_word_count == BURST_SIZE-1) begin
                    src_burst_word_count <= 0;
                    src_block_binary <= src_block_binary + 1'b1;
                    src_block_gray <= ((src_block_binary + 1'b1) >> 1) ^
                                      (src_block_binary + 1'b1);
                end else begin
                    src_burst_word_count <= src_burst_word_count + 1'b1;
                end
            end
        end
    end

    // 目的域：把攒好的块一笔笔写进 SDRAM，每写完一笔块计数加1
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            prefetch_pending <= 1'b0;
            burst_first <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            src_block_gray_sync1 <= 0;
            src_block_gray_sync2 <= 0;
            dst_block_binary <= 0;
            dst_block_gray <= 0;
        end else begin
            src_block_gray_sync1 <= src_block_gray;
            src_block_gray_sync2 <= src_block_gray_sync1;
            if (prefetch_request) prefetch_pending <= 1'b1;
            if (prefetch_pending && fifo_rd_valid) begin
                prefetch_pending <= 1'b0;
                burst_active <= 1'b1;
                burst_first <= 1'b1;
                burst_remaining <= BURST_SIZE;
            end
            if (dst_app_wr_en) begin
                burst_first <= 1'b0;
                if (burst_remaining == 1) begin
                    burst_active <= 1'b0;
                    burst_remaining <= 0;
                    dst_block_binary <= dst_block_binary + 1'b1;
                    dst_block_gray <= ((dst_block_binary + 1'b1) >> 1) ^
                                      (dst_block_binary + 1'b1);
                end else begin
                    burst_remaining <= burst_remaining - 1'b1;
                end
            end
        end
    end

    // FIFO 里一条命令 = 地址(21位) + mask(4位) + 数据(32位)
    assign dst_app_wr_addr = fifo_rd_data[COMMAND_WIDTH-1:36];
    assign dst_app_wr_mask = fifo_rd_data[35:32];
    assign dst_app_wr_data = fifo_rd_data[31:0];
    // 彻底空闲：FIFO空、没有待搬的块、没有突发在跑、也没有预取的字在手
    assign dst_idle = fifo_empty && !block_pending &&
                      !burst_active && !prefetch_pending && !fifo_rd_valid;
endmodule

// -----------------------------------------------------------------------------
// 自制的异步命令FIFO（本文件内部使用）
// 读写在两个时钟域，指针各自转 Gray 码后打两拍过域：
//   - 写满判断：写指针的"下一Gray值"等于读指针Gray最高两位取反——这是标准做法，
//     保证不会把未读数据覆盖掉；
//   - 读空判断：读指针Gray值等于同步过来的写指针Gray值；
//   - rd_level：把同步过来的写指针Gray还原成二进制，减去读指针，得到当前可读个数。
// Gray码的意义：每次只变一位，跨域采样时最多错一拍，不会读出乱指针。
// -----------------------------------------------------------------------------
module async_command_fifo #(
    parameter integer DATA_WIDTH = 57,
    parameter integer ADDR_WIDTH = 9
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_valid,
    output reg                   rd_empty,
    output wire [ADDR_WIDTH:0]   rd_level
);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;
    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_binary;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] rd_binary;
    reg [PTR_WIDTH-1:0] rd_gray;
    reg [PTR_WIDTH-1:0] rd_gray_sync1;
    reg [PTR_WIDTH-1:0] rd_gray_sync2;
    reg [PTR_WIDTH-1:0] wr_gray_sync1;
    reg [PTR_WIDTH-1:0] wr_gray_sync2;

    wire wr_accept = wr_en && !wr_full;
    wire rd_accept = rd_en && !rd_empty;
    wire [PTR_WIDTH-1:0] wr_binary_next = wr_binary + wr_accept;
    wire [PTR_WIDTH-1:0] rd_binary_next = rd_binary + rd_accept;
    wire [PTR_WIDTH-1:0] wr_gray_next =
        (wr_binary_next >> 1) ^ wr_binary_next;
    wire [PTR_WIDTH-1:0] rd_gray_next =
        (rd_binary_next >> 1) ^ rd_binary_next;
    wire wr_full_next = wr_gray_next ==
        {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
         rd_gray_sync2[PTR_WIDTH-3:0]};
    wire rd_empty_next = rd_gray_next == wr_gray_sync2;

    // Gray → 二进制：最高位照抄，其余各位从高位往低位逐个异或还原
    function [PTR_WIDTH-1:0] gray_to_binary;
        input [PTR_WIDTH-1:0] value;
        integer bit_index;
        begin
            gray_to_binary[PTR_WIDTH-1] = value[PTR_WIDTH-1];
            for (bit_index = PTR_WIDTH-2; bit_index >= 0;
                 bit_index = bit_index - 1)
                gray_to_binary[bit_index] =
                    gray_to_binary[bit_index+1] ^ value[bit_index];
        end
    endfunction

    wire [PTR_WIDTH-1:0] wr_binary_rd = gray_to_binary(wr_gray_sync2);
    assign rd_level = wr_binary_rd - rd_binary;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_binary <= 0;
            wr_gray <= 0;
            rd_gray_sync1 <= 0;
            rd_gray_sync2 <= 0;
            wr_full <= 1'b0;
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
            if (wr_accept)
                memory[wr_binary[ADDR_WIDTH-1:0]] <= wr_data;
            wr_binary <= wr_binary_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_binary <= 0;
            rd_gray <= 0;
            wr_gray_sync1 <= 0;
            wr_gray_sync2 <= 0;
            rd_data <= 0;
            rd_valid <= 1'b0;
            rd_empty <= 1'b1;
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            rd_valid <= rd_accept;
            if (rd_accept)
                rd_data <= memory[rd_binary[ADDR_WIDTH-1:0]];
            rd_binary <= rd_binary_next;
            rd_gray <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end
endmodule
