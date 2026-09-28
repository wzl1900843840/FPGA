`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
module media_hdmi_audio_bridge (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire [9:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    input wire wav_valid,wav_active,force_test,
    input wire signed [15:0] wav_sample,
    input wire [7:0] fade_gain,
    output wire wav_ready,
    output wire sample_tick,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;

    reg video_hsync_q;
    reg video_vsync_q;
    reg video_de_q;
    reg [9:0] video_x_q;
    reg [23:0] video_rgb_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            video_hsync_q <= 1'b1;
            video_vsync_q <= 1'b1;
            video_de_q <= 1'b0;
            video_x_q <= 10'd0;
            video_rgb_q <= 24'h000000;
        end else begin
            video_hsync_q <= video_hsync;
            video_vsync_q <= video_vsync;
            video_de_q <= video_de;
            video_x_q <= video_x;
            video_rgb_q <= video_de ? video_rgb : 24'h000000;
        end
    end

    wire tone_valid,tone_ready;
    wire signed [15:0] tone_left,tone_right;
    reg [24:0] rate_accumulator;
    assign sample_tick=rate_accumulator>=25000000-48000;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) rate_accumulator<=0;
        else if(sample_tick) rate_accumulator<=rate_accumulator+48000-25000000;
        else rate_accumulator<=rate_accumulator+48000;
    pcm_media_tone u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(8'd255),
        .sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),
        .overflow(tone_overflow), .blip_active(blip_active)
    );

    // 48kHz采样的1kHz测试方波，24样本半周期。未选中的合成器持续排空。
    reg [5:0] test_phase;
    reg test_valid;
    reg signed [15:0] test_sample;
    wire test_ready;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) begin test_phase<=0;test_valid<=0;test_sample<=0;end
        else begin
            if(test_ready) test_valid<=0;
            if(sample_tick && (!test_valid || test_ready)) begin
                test_phase<=test_phase==47?0:test_phase+1'b1;
                test_sample<=test_phase<24?16'sd6000:-16'sd6000;test_valid<=1;
            end
        end
    wire selected_wav=wav_active && !force_test;
    wire mux_valid,mux_ready;
    wire signed [15:0] mux_left,mux_right;
    wire arp_ready;
    audio_source_mux u_source_mux(.clk(pixel_clk),.rst_n(pixel_rst_n),
        .wav_valid(wav_valid),.wav_ready(wav_ready),.wav_left(wav_sample),.wav_right(wav_sample),
        .wav_active(wav_active),.arp_valid(force_test?test_valid:tone_valid),.arp_ready(arp_ready),
        .arp_left(force_test?test_sample:tone_left),.arp_right(force_test?test_sample:tone_right),
        .force_arpeggio(force_test),.out_valid(mux_valid),.out_ready(mux_ready),
        .out_left(mux_left),.out_right(mux_right));
    assign tone_ready=selected_wav || force_test ? 1'b1:arp_ready;
    assign test_ready=force_test?arp_ready:1'b1;
    // 增益在进入valid/ready契约适配器前计算；样本未握手时保持上游数据。
    wire [16:0] gain_product=volume*({1'b0,fade_gain}+9'd1);
    wire [7:0] gain=fade_gain==255?volume:gain_product[15:8];
    wire signed [24:0] left_product=mux_left*$signed({1'b0,gain});
    wire signed [24:0] right_product=mux_right*$signed({1'b0,gain});
    reg scaled_valid;
    reg signed [15:0] scaled_left,scaled_right;
    assign mux_ready=!scaled_valid || source_ready;
    assign source_valid=scaled_valid;
    assign source_left=scaled_left;
    assign source_right=scaled_right;
    // 接受样本时锁存增益结果，背压期间参数变化不能改变有效样本。
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) begin scaled_valid<=0;scaled_left<=0;scaled_right<=0;end
        else if(mux_ready) begin
            scaled_valid<=mux_valid;
            if(mux_valid) begin
                scaled_left<=gain==255?mux_left:left_product>>>8;
                scaled_right<=gain==255?mux_right:right_product>>>8;
            end
        end

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(source_valid), .source_ready(source_ready),
        .source_left(source_left), .source_right(source_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    hdmi_audio_symbol_core u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync_q), .video_vsync(video_vsync_q),
        .video_de(video_de_q), .video_x(video_x_q), .video_rgb(video_rgb_q),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );

    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;
endmodule
