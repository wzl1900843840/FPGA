`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
//
// 模块职责：HDMI 音频"源头选择 + 音量缩放 + 契约适配"的边界层。
// 位置：上游是顶层已寄存的视频束（hsync/vsync/de/x/rgb）和音频源（wav_stream_player、
//       pcm_media_tone、1kHz 测试音），下游是 hdmi_audio_symbol_core 的 Data Island 打包。
// 时钟域：整模块只跑 25MHz 像素时钟 pixel_clk，不跨域；48kHz 采样节拍由像素时钟分频产生。
// 输入约定：wav_valid/sample_tick 的 wav 源、media_id 决定合成音调、force_test 强制测试音、
//          fade_gain 是转场增益、volume 是用户音量（0~255）。
// 输出约定：channelN_symbol 是已编码的 10bit TMDS 符号；wav_ready 反压 wav 源；
//          pcm_tap_valid/pcm_tap_left 把最终送出链路的样本抽头给波形显示模块。
// 关键点：音量/增益只在"样本被接受"的那一拍锁存，背压期间参数变化不会改写已生效样本。
module media_hdmi_audio_bridge #(
    parameter integer ALARM_SOUND_ENABLE = 1
) (
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
    output wire signed [15:0] pcm_tap_left,
    input wire alarm_active
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;

    // ===== 视频束寄存：把 hsync/vsync/de/x/rgb 整体延后一拍 =====
    // 下游 Data Island 打包和 TMDS 编码都有一拍寄存，这里同步延后保证视频与
    // 音频岛在同一条流水线上对齐；消隐期把 RGB 清零，避免编码出无效像素。
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

    // ===== 音频源：合成音调 + 1kHz 测试音 + WAV，三选一 =====
    // 25MHz 像素时钟下的 48kHz 采样节拍发生器：累加器每拍加 48000，
    // 超过 25000000 就溢出一次，溢出拍即一个采样点（占空比等效 48kHz）。
    // 用加法代替除法，避免在像素时钟上引入除法器。
    wire tone_valid,tone_ready;
    wire signed [15:0] tone_left,tone_right;
    reg [24:0] rate_accumulator;
    assign sample_tick=rate_accumulator>=25000000-48000;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) rate_accumulator<=0;
        else if(sample_tick) rate_accumulator<=rate_accumulator+48000-25000000;
        else rate_accumulator<=rate_accumulator+48000;
    // 合成音调源：按 media_id（当前图片编号）选音高，构成"换图换声音"的联动。
    // 这里固定用 8'd255 幅度，真正的用户音量统一放到后面的增益级，避免两处相乘。
    pcm_media_tone u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(8'd255),
        .sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),
        .overflow(tone_overflow), .blip_active(blip_active)
    );

    // 48kHz采样的1kHz测试方波，24样本半周期。未选中的合成器持续排空。
    // 周期 48 个采样点 = 48kHz/48 = 1kHz；前 24 点 +6000、后 24 点 −6000 构成方波。
    // 只在 test_ready 时接受新样本，且旧样本必须先被取走（!test_valid || test_ready），
    // 因此被选中的源不会丢样本；未选中的源靠 ready 恒为 1 持续排空，保持相位连续。
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
    // ===== 源选择：WAV 优先，force_test 强制测试音，否则合成音调 =====
    // 优先级由 audio_source_mux 内部决定：force_test 时一定取测试音；
    // 否则若 wav 正在播放就取 WAV；两者都没有才取合成音调。
    // tone_ready/test_ready 的写法是"让落选的那一路照常被取走"，
    // 这样切源时不会因为对方 ready=0 而卡住流水线。
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
    // ===== 增益级：音量 × 转场增益，乘法器输出寄存 =====
    // gain = volume * (fade_gain+1) / 256：fade_gain 满量程时走 255 直通分支，
    // 避免"满音量仍被右移 8 位"造成 −0.03dB 的固定衰减。
    // 乘法结果只在 mux_ready（本拍样本能被接受）时写入 scaled_*，所以背压期间
    // volume/fade_gain 变化不会改写已经生效的那个样本，这是音量无爆音的关键。
    // 增益在进入valid/ready契约适配器前计算；样本未握手时保持上游数据。
    // Three independent 1 kHz beeps at 48 kHz: 200 ms on/off/on/off/on.
    // An elastic source holds valid/data under backpressure. User mute/fade
    // apply only to normal audio; alarm amplitude is capped at 4096/32768.
    reg alarm_seen,alarm_playing,alarm_valid;
    reg [2:0] alarm_segment;
    reg [13:0] alarm_samples;
    reg [5:0] alarm_phase;
    reg [6:0] alarm_envelope,normal_envelope;
    reg signed [15:0] alarm_sample;
    wire alarm_requested=ALARM_SOUND_ENABLE && (alarm_active === 1'b1);
    wire alarm_override=ALARM_SOUND_ENABLE && alarm_playing;
    wire alarm_ready=!alarm_override || mux_ready;
    wire alarm_loud=alarm_requested && !alarm_segment[0] && alarm_samples<9536;
    wire signed [15:0] alarm_level=$signed({3'd0,alarm_envelope,6'd0});
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) begin
            alarm_seen<=0;alarm_playing<=0;alarm_valid<=0;
            alarm_segment<=0;alarm_samples<=0;alarm_phase<=0;
            alarm_envelope<=0;normal_envelope<=64;alarm_sample<=0;
        end else begin
            alarm_seen<=alarm_requested;
            if(alarm_ready) alarm_valid<=0;
            if(alarm_requested && !alarm_seen) begin
                alarm_playing<=1;alarm_segment<=0;alarm_samples<=0;
                alarm_phase<=0;alarm_envelope<=0;
            end
            if(sample_tick && (!alarm_valid || alarm_ready)) begin
                if(alarm_playing) begin
                    alarm_valid<=1;
                    alarm_sample<=alarm_phase<24 ? alarm_level : -alarm_level;
                    alarm_phase<=alarm_phase==47 ? 0 : alarm_phase+1'b1;
                    if(alarm_loud) begin
                        if(alarm_envelope<64) alarm_envelope<=alarm_envelope+1'b1;
                    end else if(alarm_envelope!=0) alarm_envelope<=alarm_envelope-1'b1;
                    if(!alarm_requested) begin
                        if(alarm_envelope==0) alarm_playing<=0;
                    end else if(alarm_samples==9599) begin
                        alarm_samples<=0;alarm_phase<=0;
                        if(alarm_segment==4) alarm_playing<=0;
                        else alarm_segment<=alarm_segment+1'b1;
                    end else alarm_samples<=alarm_samples+1'b1;
                    normal_envelope<=0;
                end else if(normal_envelope<64) normal_envelope<=normal_envelope+1'b1;
            end
        end
    wire [16:0] gain_product=volume*({1'b0,fade_gain}+9'd1);
    wire [7:0] user_gain=fade_gain==255?volume:gain_product[15:8];
    wire [14:0] recovery_product=user_gain*normal_envelope;
    wire [7:0] gain=normal_envelope==64 ? user_gain : recovery_product[13:6];
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
            scaled_valid<=alarm_override ? alarm_valid : mux_valid;
            if(alarm_override && alarm_valid) begin
                scaled_left<=alarm_sample;scaled_right<=alarm_sample;
            end else if(!alarm_override && mux_valid) begin
                scaled_left<=gain==255?mux_left:left_product>>>8;
                scaled_right<=gain==255?mux_right:right_product>>>8;
            end
        end

    // ===== 契约适配 + 符号编码 =====
    // m06 适配器把本模块的 valid/ready 样本握手整理成 HDMI 链路约定的
    // pcm_valid/pcm_ready 形式，并上报握手违约（contract_error）。
    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(source_valid), .source_ready(source_ready),
        .source_left(source_left), .source_right(source_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    // 符号核：负责 Data Island 打包、ACR/InfoFrame、Data Island 映射与 TMDS 编码。
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

    // 波形显示抽头：只在实际完成握手的样本上有效，显示端看到的
    // 就是真正送进 HDMI 的那个样本（含音量与转场增益）。
    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;
endmodule
