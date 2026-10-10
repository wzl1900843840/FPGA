`timescale 1ns/1ps

// 模块职责：HDMI 音频链的"打包 + 岛调度 + 编码"总装层。
// 位置：上游是 media_hdmi_audio_bridge 送来的 PCM 样本，下游是 lane_lvds_10_1 的
//       10bit TMDS 符号串化器；本模块输出三通道符号即可直接进 PHY。
// 时钟域：整模块只跑 25MHz 像素时钟（pixel_clk），与视频时序同域，不需要跨域握手。
// 输入约定：video_x 是 0~799 的像素计数，消隐期也继续计数，Data Island 的位置就靠它判定；
//          sample_valid/ready 是 PCM 样本握手。
// 输出约定：channelN_symbol 每拍一个 10bit 符号（含视频期/控制期/数据岛期三种内容）；
//          sequence_error 表示岛内控制序列或包顺序异常，只做诊断，不影响出图。
//
// 一条 Data Island 的完整流水（按像素横坐标划分，见下面 video_preamble/guard/island_slot）：
//   x=790~797 前导码：三通道发送控制字符，预告"后面是数据岛"
//   x=798~799 保护带：过渡区，让接收端有时间切换
//   x=652     数据岛：每个像素位置携带 4bit TERC4 数据，逐像素推进岛内字节
// 三个包源（音频样本包、ACR 时钟再生包、InfoFrame 包）同时准备好，由调度器
// 在岛开始处"锁定"其中一个，整包发完再换下一个，保证包不会被拦腰截断。
module hdmi_audio_symbol_core #(
    parameter integer ACR_INTERVAL_CYCLES = 25000
) (
    input  wire               pixel_clk,
    input  wire               rst_n,
    input  wire               video_hsync,
    input  wire               video_vsync,
    input  wire               video_de,
    input  wire [9:0]         video_x,
    input  wire [23:0]        video_rgb,
    input  wire               sample_valid,
    output wire               sample_ready,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    output wire [9:0]         channel0_symbol,
    output wire [9:0]         channel1_symbol,
    output wire [9:0]         channel2_symbol,
    output wire               sequence_error
);
    // ===== 视频时序边界判定：用像素横坐标切出前导码/保护带/数据岛 =====
    // previous_vsync 用来抓 vsync 的下降沿，作为"每帧一次"的 InfoFrame 触发点。
    // island_slot 固定取 x=652（水平消隐区内），一个像素位置放 4bit×3 通道。
    reg previous_vsync;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            previous_vsync <= 1'b1;
        end else begin
            previous_vsync <= video_vsync;
        end
    end

    // 790~797 前导码、798~799 保护带：HDMI 规定数据岛前必须先发这两个区，
    // 接收端靠它们判断"接下来是数据而不是视频"，这里只做位置解码。
    wire video_preamble = video_x >= 10'd790 && video_x <= 10'd797;
    wire video_guard = video_x >= 10'd798;
    wire island_slot = video_x == 10'd652;
    wire info_emit = previous_vsync && !video_vsync;

    // ===== 三个包源并行准备（都只做打包，不决定何时发） =====
    // 音频样本包：把 PCM 左右声道样本按 IEC 60958 子帧格式装进 4 字节体，
    // 同时算好包头 BCH 校验和包体 BCH 校验，交给调度器排队。
    wire audio_valid, audio_ready;
    wire [23:0] audio_header;
    wire [7:0] audio_header_ecc;
    wire [223:0] audio_body;
    wire [31:0] audio_body_ecc;
    wire [7:0] packet_frame_base_unused;
    hdmi_audio_sample_packetizer u_audio_packetizer (
        .clk(pixel_clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .packet_valid(audio_valid), .packet_ready(audio_ready),
        .packet_header(audio_header),
        .packet_header_ecc(audio_header_ecc),
        .packet_body(audio_body), .packet_body_ecc(audio_body_ecc),
        .packet_frame_base(packet_frame_base_unused)
    );

    // ACR（Audio Clock Regeneration）包：告诉显示器"音频采样时钟相对像素时钟是多少"，
    // 接收端用它恢复 48kHz。ACR_N/ACR_CTS = 6144/25000 对应 48kHz 与 25MHz 像素时钟的比值，
    // INTERVAL_CYCLES 决定多久发一次（越小同步越快、占用岛越多）。
    wire acr_valid, acr_ready;
    wire [23:0] acr_header;
    wire [7:0] acr_header_ecc;
    wire [223:0] acr_body;
    wire [31:0] acr_body_ecc;
    hdmi_audio_acr_packetizer #(
        .INTERVAL_CYCLES(ACR_INTERVAL_CYCLES),
        .ACR_N(20'd6144),
        .ACR_CTS(20'd25000)
    ) u_acr_packetizer (
        .clk(pixel_clk), .rst_n(rst_n),
        .packet_valid(acr_valid), .packet_ready(acr_ready),
        .packet_header(acr_header), .packet_header_ecc(acr_header_ecc),
        .packet_body(acr_body), .packet_body_ecc(acr_body_ecc)
    );

    // InfoFrame 包：描述音频流本身的属性（声道数、采样率等），每帧发一次就够，
    // 用 info_emit（vsync 下降沿）触发，接收端据此建立音频参数。
    wire info_valid, info_ready;
    wire [23:0] info_header;
    wire [7:0] info_header_ecc;
    wire [223:0] info_body;
    wire [31:0] info_body_ecc;
    hdmi_audio_infoframe_packetizer u_info_packetizer (
        .clk(pixel_clk), .rst_n(rst_n), .emit(info_emit),
        .packet_valid(info_valid), .packet_ready(info_ready),
        .packet_header(info_header),
        .packet_header_ecc(info_header_ecc),
        .packet_body(info_body), .packet_body_ecc(info_body_ecc)
    );

    // ===== 包调度：岛开始处锁定一个包源，整包发完再换 =====
    // packet_claim（下游叫 packet_lock）由岛调度器在数据岛开始的那一拍拉高，
    // 调度器据此把当前包"钉住"，避免同一像素位置上三个源互相抢占导致包内容混串。
    wire packet_valid;
    wire packet_claim;
    wire packet_ready;
    wire [1:0] packet_source_unused;
    wire [23:0] packet_header;
    wire [7:0] packet_header_ecc;
    wire [223:0] packet_body;
    wire [31:0] packet_body_ecc;
    hdmi_audio_packet_scheduler u_packet_scheduler (
        .clk(pixel_clk), .rst_n(rst_n),
        .acr_valid(acr_valid), .acr_ready(acr_ready),
        .acr_header(acr_header), .acr_header_ecc(acr_header_ecc),
        .acr_body(acr_body), .acr_body_ecc(acr_body_ecc),
        .info_valid(info_valid), .info_ready(info_ready),
        .info_header(info_header), .info_header_ecc(info_header_ecc),
        .info_body(info_body), .info_body_ecc(info_body_ecc),
        .audio_valid(audio_valid), .audio_ready(audio_ready),
        .audio_header(audio_header), .audio_header_ecc(audio_header_ecc),
        .audio_body(audio_body), .audio_body_ecc(audio_body_ecc),
        .packet_valid(packet_valid), .packet_lock(packet_claim),
        .packet_ready(packet_ready),
        .packet_source(packet_source_unused),
        .packet_header(packet_header),
        .packet_header_ecc(packet_header_ecc),
        .packet_body(packet_body), .packet_body_ecc(packet_body_ecc)
    );

    // ===== 岛调度 + 通道映射 + TMDS 编码 =====
    // 岛调度器：根据 video_active/preamble/guard/island_slot 产生 mode（视频/控制/数据岛），
    // 并在数据岛期把 24bit 包头 + 224bit 包体按每像素 4bit 逐拍推到映射器；
    // sequence_error 表示控制序列（如 CTL 周期）出现异常。
    wire [2:0] mode;
    wire [1:0] control0, control1, control2;
    wire [4:0] packet_pixel_index;
    wire [23:0] active_header;
    wire [7:0] active_header_ecc;
    wire [223:0] active_body;
    wire [31:0] active_body_ecc;
    wire sequence_active_unused;
    hdmi_data_island_scheduler u_island_scheduler (
        .clk(pixel_clk), .rst_n(rst_n),
        .video_active(video_de), .video_preamble(video_preamble),
        .video_guard(video_guard), .island_slot(island_slot),
        .hsync(video_hsync), .vsync(video_vsync),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_claim(packet_claim),
        .packet_header(packet_header),
        .packet_header_ecc(packet_header_ecc),
        .packet_body(packet_body), .packet_body_ecc(packet_body_ecc),
        .mode(mode), .channel0_control(control0),
        .channel1_control(control1), .channel2_control(control2),
        .packet_pixel_index(packet_pixel_index),
        .active_header(active_header),
        .active_header_ecc(active_header_ecc),
        .active_body(active_body), .active_body_ecc(active_body_ecc),
        .sequence_active(sequence_active_unused),
        .sequence_error(sequence_error)
    );

    // 岛映射器：把包头（含 BCH 纠错）、包体、包体 BCH 拼成 24bit×3 通道的
    // 顺序位流，再切成每通道 4bit 一组交给 TERC4 编码；包体末端补 32bit BCH，
    // 接收端用它能纠正岛内单比特错误，所以音频岛比视频像素更抗噪。
    wire [3:0] island0, island1, island2;
    hdmi_data_island_mapper u_island_mapper (
        .pixel_index(packet_pixel_index),
        .hsync(video_hsync), .vsync(video_vsync),
        .packet_header(active_header),
        .packet_header_ecc(active_header_ecc),
        .packet_body(active_body), .packet_body_ecc(active_body_ecc),
        .channel0_terc4(island0), .channel1_terc4(island1),
        .channel2_terc4(island2)
    );

    // 三通道 TMDS 编码器：CHANNEL 参数决定用哪条通道的控制字符表。
    // 编码器按 mode 在三种输入间切换：视频期编 8bit 像素（通道0/1/2 分别取 R/G/B），
    // 数据岛期编 4bit TERC4，控制期编 2bit 控制字符；输出恒为 10bit 符号。
    hdmi_tmds_channel_encoder #(.CHANNEL(0)) u_encoder0 (
        .clk(pixel_clk), .rst_n(rst_n), .mode(mode),
        .video_data(video_rgb[7:0]), .data_island_data(island0),
        .control_data(control0), .symbol(channel0_symbol)
    );
    hdmi_tmds_channel_encoder #(.CHANNEL(1)) u_encoder1 (
        .clk(pixel_clk), .rst_n(rst_n), .mode(mode),
        .video_data(video_rgb[15:8]), .data_island_data(island1),
        .control_data(control1), .symbol(channel1_symbol)
    );
    hdmi_tmds_channel_encoder #(.CHANNEL(2)) u_encoder2 (
        .clk(pixel_clk), .rst_n(rst_n), .mode(mode),
        .video_data(video_rgb[23:16]), .data_island_data(island2),
        .control_data(control2), .symbol(channel2_symbol)
    );
endmodule
