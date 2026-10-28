`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 帧读取器：把 SDRAM 里的一张图，按 25MHz 像素节拍连续喂给显示链
//
// 两个时钟域：
//   内存域 mem_clk(40MHz)：发突发读命令、数返回、写进跨域FIFO；
//   像素域 pix_clk(25MHz)：每帧开始时请求"换到第 N 张图"，然后一拍一个像素取走。
//
// 工作过程（一帧）：
//   1) 像素域在 frame_start 时置 request_pending，下一拍把 active_index 和
//      request_toggle 发给内存域（延迟一拍是为了让上游先把图号提交好）；
//   2) 内存域看到 toggle 变化就重载：issued/returned 计数清零、FIFO 复位、
//      reader_index 换成新图号，然后从 bank_base(图号) 开始发读；
//   3) 读请求按 BURST_SIZE=128 字一笔，一笔发完要隔 BURST_GAP_CYCLES 拍再发下一笔；
//   4) 同时在飞的字数不超过 MAX_INFLIGHT_BURSTS*BURST_SIZE，且要保证
//      FIFO 里已有字数 + 在飞字数 + 下一笔不会超过 FIFO_DEPTH-FIFO_MARGIN
//      （这两个"闸门"就是 inflight_window_ok / fifo_reservation_ok）；
//   5) 返回数据写进跨域FIFO，像素域经 fifo_prefetch_2 提前取出一个像素，
//      所以 pixel_valid 总是提前就绪，正常情况不会欠载。
//
// 四个错误码分别代表：换图太快(61)、FIFO写满(62)、显示欠载(63)、帧不完整(64)。
// read_urgent 表示 FIFO 水位低于一半，交给顶层仲裁器让视频优先拿总线。
//
// 诊断旁路：synth_stream=1 时完全不读 SDRAM，直接由本模块合成彩条/灰阶/棋盘格
// 写进 FIFO，用来单独验证"显示链 + FIFO"是否正常（与 SDRAM 数据无关）。
// -----------------------------------------------------------------------------
module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    parameter integer RUNTIME_DIAG = 0,
    parameter integer SHARED_MEMORY = 0
) (
    input  wire                  diag_synth_stream,
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [2:0]            active_index,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [2:0]            reader_index,
    output reg  [7:0]            reader_error,
    input  wire                 burst_grant,
    output wire                 burst_request,
    output wire                 read_urgent,
    output reg [8:0] diagnostic_fifo_min,output reg [15:0] diagnostic_underflows
);
    // Runtime selection is latched at boot, before any frame request.
    wire synth_stream = DIAG_SYNTH_STREAM || (RUNTIME_DIAG && diag_synth_stream);
    wire accepted_return = sdram_rd_valid && !synth_stream;
    // 错误码：61=换图时上一帧还没读完，62=FIFO被写满，63=显示欠载，64=帧不完整
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg request_pending_pix;
    reg request_toggle_pix;
    reg [2:0] request_index_pix;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [2:0] index_sync1_mem;
    reg [2:0] index_sync2_mem;
    reg reload_pending_mem;
    reg [2:0] reload_index_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [9:0] diag_column_mem;
    reg [9:0] diag_row_mem;
    reg [23:0] diag_rgb_mem;
    (* async_reg = "true" *) reg [1:0] fifo_release_mem;
    (* async_reg = "true" *) reg [1:0] fifo_release_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    // The request contains both clock domains. It may assert at any phase,
    // so each hold-extension chain must assert asynchronously and release
    // only on its own two clock edges, rather than sampling raw reset as D.
    always @(posedge mem_clk or posedge fifo_reset_request)
        if(fifo_reset_request) fifo_release_mem<=2'b00;
        else fifo_release_mem<={fifo_release_mem[0],1'b1};
    always @(posedge pix_clk or posedge fifo_reset_request)
        if(fifo_reset_request) fifo_release_pix<=2'b00;
        else fifo_release_pix<={fifo_release_pix[0],1'b1};
    (* async_reg = "true" *) reg [1:0] fifo_ready_mem;
    (* async_reg = "true" *) reg [1:0] prefetch_release_pix;
    wire prefetch_reset_pix = !prefetch_release_pix[1];
    // A common FIFO flush is required on both sides, but ordinary pixel
    // registers must only leave reset on their own clock. Keep the FIFO read
    // port quiet until its internal two-stage reset release has also finished.
    always @(posedge pix_clk or posedge fifo_reset)
        if (fifo_reset) prefetch_release_pix <= 2'b00;
        else prefetch_release_pix <= {prefetch_release_pix[0], 1'b1};
    // FIFO 公共复位异步拉低就绪；只在写时钟域同步释放后发出突发。
    always @(posedge mem_clk or posedge fifo_reset)
        if(fifo_reset) fifo_ready_mem<=0;
        else fifo_ready_mem<={fifo_ready_mem[0],1'b1};
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid;
    reg diagnostic_started;
    reg [15:0] diagnostic_underflows_pix;
    always @(posedge pix_clk or negedge pix_rst_n)
        if(!pix_rst_n)diagnostic_underflows_pix<=0;
        else if(pixel_consume && !prefetch_valid && diagnostic_underflows_pix!=16'hffff)
            diagnostic_underflows_pix<=diagnostic_underflows_pix+1'b1;
    wire [15:0] underflows_snapshot;
    frame_config_cdc #(.WIDTH(16)) u_underflows_commit(
        .src_clk(pix_clk),.src_rst_n(pix_rst_n),.src_data(diagnostic_underflows_pix),
        .dst_clk(mem_clk),.dst_rst_n(mem_rst_n),.frame_start(1'b1),.dst_data(underflows_snapshot));
    always @(posedge mem_clk or negedge mem_rst_n)
        if(!mem_rst_n)begin diagnostic_fifo_min<=511;diagnostic_started<=0;diagnostic_underflows<=0;end
        else begin
            diagnostic_underflows<=underflows_snapshot;
            // Ordinary diagnostic CE logic must use the mem-domain release,
            // never the raw common reset which also contains pix_rst_n.
            // Rearm for every flush: the new frame's intentional empty fill
            // interval must not overwrite the lifetime minimum with zero.
            if(!fifo_ready_mem[1])diagnostic_started<=0;
            else if(fifo_wrusedw>=256)diagnostic_started<=1;
            // Exclude intentional flushes and the finite frame's natural tail.
            if(diagnostic_started && fifo_ready_mem[1] && !reload_pending_mem && reader_busy &&
                issued_count_mem<IMAGE_WORDS && fifo_wrusedw<diagnostic_fifo_min)
                diagnostic_fifo_min<=fifo_wrusedw;
        end
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == IMAGE_WORDS - 1;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire [ADDR_WIDTH:0] next_burst_words =
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_words};
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        ((inflight_words + next_burst_words) <=
         (MAX_INFLIGHT_BURSTS * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    assign read_urgent=fifo_wrusedw <= FIFO_DEPTH/2;
    assign burst_request = !synth_stream && reader_busy && controller_init_done &&
                       !reload_pending_mem && request_sync2_mem == request_seen_mem &&
                       fifo_ready_mem[1] && !burst_active_mem &&
                       !controller_busy && !refresh_active &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != IMAGE_WORDS &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire start_burst=burst_request && (!SHARED_MEMORY || burst_grant);
    wire issue_allowed = !synth_stream && reader_busy && burst_active_mem;
    wire diag_stream_write = synth_stream && reader_busy &&
                             fifo_ready_mem[1] && !fifo_full;
    wire fifo_write_enable = synth_stream ? diag_stream_write :
                             (sdram_rd_valid && fifo_ready_mem[1] && !fifo_full);
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || synth_stream) ?
                                  {8'h00, diag_rgb_mem} : sdram_rd_data;

    // 诊断图案：默认8色彩条；synth_stream 模式下改成灰阶/彩色渐变+棋盘格
    always @* begin
        if(synth_stream && diag_row_mem>=360) begin
            if(diag_column_mem<512)
                diag_rgb_mem={diag_column_mem[7:0],diag_row_mem[7:0],diag_column_mem[7:0]^diag_row_mem[7:0]};
            else diag_rgb_mem=(diag_column_mem[3]^diag_row_mem[3])?24'hffffff:0;
        end else if(synth_stream && diag_row_mem>=240)
            diag_rgb_mem={diag_column_mem[7:0],diag_column_mem[7:0],diag_column_mem[7:0]};
        else if (diag_column_mem < 10'd80)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < 10'd160)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < 10'd240)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < 10'd320)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < 10'd400)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < 10'd480)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < 10'd560)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    // SDRAM 里五张图各占 IMAGE_WORDS 个32位字，图号 → 起始地址；第5张是紧急页面
    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = {ADDR_WIDTH{1'b0}};
                3'd1: bank_base = IMAGE_WORDS;
                3'd2: bank_base = IMAGE_WORDS * 2;
                3'd3: bank_base = IMAGE_WORDS * 3;
                3'd5: bank_base = IMAGE_WORDS * 5; // thumbnail cache, frame-latched
                default: bank_base = IMAGE_WORDS * 4;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    // 像素域：帧边界发换图请求 + 统计本帧消费了多少像素（用来判断欠载）
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 3'd0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
        end else begin
            if (frame_start) begin
                if (frame_armed_pix && consumed_count_pix != IMAGE_WORDS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
            end else if (request_pending_pix) begin
                request_index_pix <= active_index;
                request_toggle_pix <= ~request_toggle_pix;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= 1'b1;
            end

            if (pixel_consume) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix)
                    underflow <= 1'b1;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 3'd0;
            index_sync2_mem <= 3'd0;
            reload_pending_mem <= 1'b0;
            reload_index_mem <= 3'd0;
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
                diag_row_mem <= 0;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 3'd0;
            reader_error <= ERR_NONE;
        end else begin
            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            // 在飞字数统计：这一拍既发出命令又收到返回时，净变化为0，保持原值
            case ({issue_allowed, accepted_return})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            // Reload stops NEW grants only. An authorized burst must still issue
            // all words and receive every return before the FIFO is flushed.
            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                if (reader_busy || !inflight_empty_mem) begin
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            // 等在飞数据全部返回（inflight_empty）才真正换图：
            // 清计数器、复位FIFO、切换图号，然后开始读新的一帧
            if (reload_pending_mem && inflight_empty_mem && !burst_active_mem &&
                !app_rd_en && request_sync2_mem == request_seen_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= reload_index_mem;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                diag_row_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            // 开始一笔新突发：记住本笔要发多少个字（末笔可能不足128）
            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words[BURST_COUNT_W-1:0];
            end

            // 逐字发读命令：地址 = 图号基址 + 已发字数
            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                app_rd_addr <= bank_base(reader_index) + issued_count_mem[ADDR_WIDTH-1:0];
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;               // 本笔发完，进间隔
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            // 读返回计数：写满FIFO(62)或整帧读完(64)都结束本帧
            if (!synth_stream && sdram_rd_valid) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full) begin
                    // Flag/drop overflow but finish ownership; truncating the
                    // granted burst would strand the shared arbiter forever.
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            if (synth_stream && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                if(diag_column_mem==639) diag_row_mem<=diag_row_mem+1'b1;
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!synth_stream && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
            end
        end
    end

    // 跨时钟域FIFO：内存域写入，像素域读出（Gray指针在IP内部处理）
    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    // 预取一级：像素域提前把FIFO里的下一个像素取出来，这样 pixel_valid 不会临时才有效
    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(prefetch_reset_pix), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = prefetch_data[23:0];
    assign pixel_valid = prefetch_valid;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            // The memory-domain error remains authoritative for controller faults.
        end else if (underflow) begin
            // underflow is exported separately; the Top may merge it as 8'h63.
        end
    end

endmodule
