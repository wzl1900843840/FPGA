`timescale 1ns/1ps

module media_video_pipeline #(
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 16,
    parameter integer H_ACT = 640,
    parameter integer H_FP = 16,
    parameter integer H_SYNC = 96,
    parameter integer H_BP = 48,
    parameter integer V_ACT = 480,
    parameter integer V_FP = 10,
    parameter integer V_SYNC = 2,
    parameter integer V_BP = 33,
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // Non-zero enables the fade-out/black/fade-in transition on manual
    // switches and a fade-in on automatic slideshow switches. Zero keeps the
    // legacy direct-switch behaviour for the existing regression suites.
    parameter integer FADE_FRAMES = 0,
    parameter integer ENABLE_COLOR_ADJUST = 0,
    parameter integer RUNTIME_DIAG = 0
) (
    input  wire        diag_fifo_pix,
    input  wire        diag_fifo_mem,
    input  wire        ctrl_clk,
    input  wire        ctrl_rst_n,
    input  wire        next_event,
    input  wire        previous_event,
    input  wire        select_valid,
    input  wire [1:0]  select_index,
    input  wire        view_mode,
    input  wire        mode_transition,
    input  wire [1:0]  focus_index,
    output wire [7:0]  transition_alpha,
    output wire        transition_active,
    output wire [9:0]  video_y,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [3:0]  image_complete,
    input  wire        player_enable,

    input  wire        mem_clk,
    input  wire        mem_rst_n,
    input  wire        controller_init_done,
    input  wire        controller_busy,
    input  wire        refresh_active,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    input  wire        sdram_rd_valid,
    input  wire [31:0] sdram_rd_data,

    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    output wire        video_clk,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_de,
    output wire [23:0] video_rgb,
    output wire [9:0]  video_x,

    output wire [1:0]  active_index,
    output wire [1:0]  pending_index,
    output wire        auto_enabled,
    output wire        frame_start,
    output wire        reader_busy,
    output wire        reader_underflow,
    output wire [7:0]  video_error
);
    wire raw_hs;
    wire raw_vs;
    wire raw_de;
    wire [11:0] raw_x;
    wire [11:0] raw_y;
    localparam integer H_BLANK = H_FP + H_SYNC + H_BP;
    wire [11:0] active_x = (raw_x >= H_BLANK) ? raw_x - H_BLANK : raw_x + H_ACT;
    reg raw_vs_q;
    reg [9:0] video_x_q;
    reg [9:0] video_y_q;
    assign video_y=video_y_q;
    wire index_commit;
    wire [7:0] control_error;
    wire request_busy;
    wire [31:0] active_period_cycles;
    wire [23:0] reader_rgb;
    wire reader_pixel_valid;
    wire reader_done;
    wire [1:0] reader_index;
    wire [7:0] reader_error;
    wire player_enable_pix;
    reg [7:0] reader_error_pix1;
    reg [7:0] reader_error_pix2;
    reg [7:0] control_error_pix1;
    reg [7:0] control_error_pix2;
    wire [23:0] selected_rgb =
        (player_enable_pix && reader_pixel_valid && reader_error_pix2 == 0) ?
        reader_rgb : 24'h000000;

    sync_2ff u_player_enable_pix (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(player_enable),
        .sync_out(player_enable_pix)
    );

    // 先调节颜色，再转场；否则低对比度会把淡出黑场抬成灰色。
    // 颜色流水级与 HS/VS/DE/坐标严格同拍，OSD 放在此流水线之后。
    wire [23:0] color_rgb;
    wire color_hs,color_vs,color_de;
    wire [11:0] color_x,color_y;
    generate if(ENABLE_COLOR_ADJUST) begin:g_color
        reg hs_q,vs_q;
        reg [11:0] x_q,y_q;
        brightness_contrast_adjust u_adjust(.clk(pix_clk),.rst_n(pix_rst_n),
            .in_de(raw_de),.rgb_in(selected_rgb),.brightness(brightness),.contrast(contrast),
            .out_de(color_de),.rgb_out(color_rgb));
        always @(posedge pix_clk or negedge pix_rst_n)
            if(!pix_rst_n) begin hs_q<=1;vs_q<=1;x_q<=0;y_q<=0;end
            else begin hs_q<=raw_hs;vs_q<=raw_vs;x_q<=active_x;y_q<=raw_y;end
        assign color_hs=hs_q;assign color_vs=vs_q;assign color_x=x_q;assign color_y=y_q;
    end else begin:g_color_bypass
        assign color_rgb=selected_rgb;assign color_de=raw_de;assign color_hs=raw_hs;
        assign color_vs=raw_vs;assign color_x=active_x;assign color_y=raw_y;
    end endgenerate

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            reader_error_pix1 <= 8'd0;
            reader_error_pix2 <= 8'd0;
            control_error_pix1 <= 8'd0;
            control_error_pix2 <= 8'd0;
        end else begin
            reader_error_pix1 <= reader_error;
            reader_error_pix2 <= reader_error_pix1;
            control_error_pix1 <= control_error;
            control_error_pix2 <= control_error_pix1;
        end
    end

    video_timing_ctrl #(
        .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
        .ACTIVE_LAST(1)
    ) u_timing (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hsync(raw_hs),
        .vsync(raw_vs), .de(raw_de), .x(raw_x), .y(raw_y)
    );

    // Fade transition: manual switch requests are held until the display has
    // faded to black, then released to the control FSM at the frame boundary.
    // The bypass branch (FADE_FRAMES=0) wires next_event straight through so
    // legacy regression timing is unchanged.
    wire fade_next_event;
    wire [7:0] fade_alpha;
    wire wipe_active;
    assign transition_alpha=fade_alpha;
    assign transition_active=(fade_alpha!=255) || wipe_active;
    wire [4:0] wipe_ramp;
    wire [1:0] transition_kind;
    video_fade_transition #(.FADE_FRAMES(FADE_FRAMES)) u_fade (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_event_in(next_event), .next_event_out(fade_next_event),
        .fade_busy(),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .player_active(player_enable_pix), .frame_start(frame_start),
        .index_commit(index_commit || mode_transition), .active_index(active_index),
        .alpha_out(fade_alpha), .fade_active(),
        .wipe_active(wipe_active), .ramp_out(wipe_ramp),
        .transition_kind(transition_kind)
    );

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            raw_vs_q <= 1'b1;
        else
            raw_vs_q <= raw_vs;
    end
    assign frame_start = raw_vs_q && !raw_vs;

    // rgb_video_adapter registers hs/vs/de/rgb by one pixel. Register x in
    // parallel so the HDMI Data Island scheduler sees the coordinate belonging
    // to the same output character, rather than the next raw VTC position.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            begin video_x_q <= 10'd0; video_y_q<=0; end
        else
            begin video_x_q <= color_x[9:0];
                video_y_q <= color_y >= V_FP+V_SYNC+V_BP ? color_y-(V_FP+V_SYNC+V_BP) : 0; end
    end
    assign video_x = video_x_q;

    media_player_control #(
        .DEFAULT_PERIOD_CYCLES(DEFAULT_PERIOD_CYCLES),
        .MIN_PERIOD_CYCLES(MIN_PERIOD_CYCLES),
        .MAX_PERIOD_CYCLES(MAX_PERIOD_CYCLES)
    ) u_control (
        .sys_clk(ctrl_clk), .sys_rst_n(ctrl_rst_n),
        .next_event(fade_next_event), .previous_event(previous_event),
        .select_valid(select_valid), .select_index(select_index),
        .toggle_auto_event(toggle_auto_event),
        .period_cfg_valid(period_cfg_valid),
        .period_cfg_cycles(period_cfg_cycles),
        .auto_cfg_valid(auto_cfg_valid),
        .auto_cfg_enabled(auto_cfg_enabled),
        .image_complete(image_complete), .auto_enabled(auto_enabled),
        .active_period_cycles(active_period_cycles),
        .pending_index(pending_index), .control_error(control_error),
        .request_busy(request_busy), .pix_clk(pix_clk),
        .pix_rst_n(pix_rst_n), .frame_start(frame_start),
        .active_index(active_index), .index_commit(index_commit)
    );

    // 缩略图合成缓存位于四个原图 bank 之后，仍沿用同一个 burst reader。
    wire [20:0] reader_address;
    wire thumb_mem;
    sync_2ff u_thumb_mem(.clk(mem_clk),.rst_n(mem_rst_n),.async_in(view_mode),.sync_out(thumb_mem));
    assign app_rd_addr=reader_address + (thumb_mem ? IMAGE_WORDS*4 : 0);
    media_frame_reader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(IMAGE_WORDS),
        .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MARGIN(FIFO_MARGIN),
        .MAX_INFLIGHT_BURSTS(2), .DIAG_RETURN_PATTERN(0),
        .DIAG_SYNTH_STREAM(0), .RUNTIME_DIAG(RUNTIME_DIAG)
    ) u_reader (
        .diag_synth_stream(diag_fifo_mem),
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_rd_en(app_rd_en), .app_rd_addr(reader_address),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .frame_start(frame_start && player_enable_pix), .active_index(view_mode ? 2'd0 : active_index),
        .pixel_consume(raw_de && player_enable_pix), .pixel_rgb(reader_rgb),
        .pixel_valid(reader_pixel_valid), .underflow(reader_underflow),
        .reader_busy(reader_busy), .frame_read_done(reader_done),
        .reader_index(reader_index), .reader_error(reader_error)
    );

    // Fade multiplies the selected frame by the ramp alpha; an automatic
    // slideshow switch instead reveals the new frame left-to-right: pixels
    // right of the moving boundary stay black, the rest show full colour.
    // With FADE_FRAMES=0 the direct assignment keeps every pixel bit-identical
    // to the legacy path so strict regression comparisons still hold.
    wire [23:0] faded_rgb;
    generate
        if (FADE_FRAMES == 0) begin : g_fade_bypass
            assign faded_rgb = color_rgb;
        end else begin : g_fade_mul
            // Session-level brightness folds into the transition alpha with
            // one extra 8x8 multiply, so the steady display and the fade both
            // scale together.
            // (brightness+1)/256 keeps full brightness bit-exact (256/256)
            // while lower steps land within 0.4% of brightness/255.
            wire [16:0] alpha_product = {1'b0,fade_alpha} * ({1'b0,brightness}+9'd1);
            wire [7:0] eff_alpha = ENABLE_COLOR_ADJUST || brightness==255 ? fade_alpha : alpha_product[15:8];
            wire [15:0] fade_mul_r = {8'd0, color_rgb[23:16]} * eff_alpha;
            wire [15:0] fade_mul_g = {8'd0, color_rgb[15:8]}  * eff_alpha;
            wire [15:0] fade_mul_b = {8'd0, color_rgb[7:0]}   * eff_alpha;
            wire [23:0] alpha_rgb =
                eff_alpha==255 ? color_rgb :
                {fade_mul_r[15:8], fade_mul_g[15:8], fade_mul_b[15:8]};
            // Reveal boundary advances one H_ACT/FADE_FRAMES column step per
            // frame; the comparison uses the same raw_x that aligns with
            // selected_rgb at this point in the pipeline.
            localparam integer WIPE_STEP = H_ACT / FADE_FRAMES;
            wire [9:0] wipe_boundary = wipe_ramp * WIPE_STEP;
            wire [6:0] blind_x_boundary = wipe_ramp * 4;
            reg transition_pixel;
            always @* begin
                case (transition_kind)
                    2'd0: transition_pixel = color_x[9:0] < wipe_boundary;
                    2'd1: transition_pixel = color_x[9:0] >= H_ACT - wipe_boundary;
                    2'd2: transition_pixel = {1'b0, color_x[5:0]} < blind_x_boundary;
                    default: transition_pixel = (color_x[6] ^ color_y[6]) ?
                        ({1'b0, color_x[5:0]} < blind_x_boundary) :
                        ({1'b0, color_x[5:0]} >= 7'd64 - blind_x_boundary);
                endcase
            end
            assign faded_rgb = wipe_active ?
                (transition_pixel ? alpha_rgb : 24'h000000) :
                alpha_rgb;
        end
    endgenerate

    // Match the existing color/coordinate latency, but exclude color and fade
    // from the FIFO isolation experiment. The normal path is unchanged.
    reg [23:0] diag_pixel_q;
    always @(posedge pix_clk or negedge pix_rst_n)
        if(!pix_rst_n) diag_pixel_q<=0;
        else diag_pixel_q<=reader_pixel_valid?reader_rgb:24'hff0080;
    wire [23:0] diag_aligned_rgb=ENABLE_COLOR_ADJUST?diag_pixel_q:reader_rgb;
    rgb_video_adapter u_video_adapter (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hs_in(color_hs),
        .vs_in(color_vs), .de_in(color_de),
        .rgb_in((RUNTIME_DIAG && diag_fifo_pix)?diag_aligned_rgb:faded_rgb), .video_clk(video_clk),
        .video_hs(video_hs), .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb)
    );

    assign video_error = reader_error_pix2 != 0 ? reader_error_pix2 :
                         reader_underflow ? 8'h63 : control_error_pix2;
endmodule
