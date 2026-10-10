`timescale 1ns/1ps

// 模块职责：三类 HDMI 音频包（ACR / InfoFrame / 音频样本）的仲裁与打包转发。
// 位置：上游是三个 packetizer（hdmi_audio_acr_packetizer / hdmi_audio_infoframe_packetizer /
//       hdmi_audio_sample_packetizer），下游是 hdmi_data_island_scheduler 和岛映射器。
// 时钟域：25MHz 像素时钟 clk，单域。
// 为什么需要它：一个数据岛位置只能放一个包，但三个包源都可能同时"有包待发"。
//   若不加仲裁，同一拍会把三份 header/body 混在一起发出，接收端解出的包必然损坏。
// 仲裁策略：默认按优先级 ACR > InfoFrame > 音频 选择；
//   一旦下游 packet_lock（岛开始的那一拍）到来，就把选中源锁进 locked_source，
//   在整包发完之前不再改选，保证包内容原子性。
// 握手：packet_valid 表示"当前输出有包"，packet_ready 由下游给出；
//   对应的源 ready（acr_ready/info_ready/audio_ready）只在"本源被选中且整包被取走"时拉高。
module hdmi_audio_packet_scheduler (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         acr_valid,
    output wire         acr_ready,
    input  wire [23:0]  acr_header,
    input  wire [7:0]   acr_header_ecc,
    input  wire [223:0] acr_body,
    input  wire [31:0]  acr_body_ecc,
    input  wire         info_valid,
    output wire         info_ready,
    input  wire [23:0]  info_header,
    input  wire [7:0]   info_header_ecc,
    input  wire [223:0] info_body,
    input  wire [31:0]  info_body_ecc,
    input  wire         audio_valid,
    output wire         audio_ready,
    input  wire [23:0]  audio_header,
    input  wire [7:0]   audio_header_ecc,
    input  wire [223:0] audio_body,
    input  wire [31:0]  audio_body_ecc,
    output wire         packet_valid,
    input  wire         packet_lock,
    input  wire         packet_ready,
    output reg  [1:0]   packet_source,
    output reg  [23:0]  packet_header,
    output reg  [7:0]   packet_header_ecc,
    output reg  [223:0] packet_body,
    output reg  [31:0]  packet_body_ecc
);
    // ===== 选中源决策：未锁定看优先级，已锁定沿用锁定的源 =====
    // locked=1 期间 selected_source 保持为 locked_source，即使有更高优先级的新包到达
    // 也不改选，这正是"整包不被打断"的实现方式。
    reg locked;
    reg [1:0] locked_source;
    wire [1:0] selected_source = locked ? locked_source :
                                      acr_valid ? 2'd0 :
                                      info_valid ? 2'd1 : 2'd2;

    // packet_valid：锁定时只有被锁定源的有效位算数；未锁定时只要任一源有效就算有包。
    // 三个 ready 的写法保证"同一拍最多只有一个源被取走"，避免一次发两份包。
    assign packet_valid = locked ?
                          ((locked_source == 2'd0) ? acr_valid :
                           (locked_source == 2'd1) ? info_valid : audio_valid) :
                          (acr_valid || info_valid || audio_valid);
    assign acr_ready = packet_ready && packet_valid &&
                       selected_source == 2'd0;
    assign info_ready = packet_ready && packet_valid &&
                        selected_source == 2'd1;
    assign audio_ready = packet_ready && packet_valid &&
                         selected_source == 2'd2;

    // ===== 锁定状态机 =====
    // 锁定条件：下游在岛开始处给了 packet_lock，且此时确实有源待发，且本拍包还没被取走。
    // 解锁条件：包被下游取走（packet_ready）或包不再有效；解锁后下一拍可重新按优先级选源。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            locked_source <= 2'd0;
        end else if (locked) begin
            if (packet_ready || !packet_valid)
                locked <= 1'b0;
        end else if (packet_lock &&
                     (acr_valid || info_valid || audio_valid)) begin
            if (!(packet_ready && packet_valid)) begin
                locked <= 1'b1;
                locked_source <= acr_valid ? 2'd0 :
                                 info_valid ? 2'd1 : 2'd2;
            end
        end
    end

    // ===== 纯组合的多路选择 =====
    // 输出默认全 0（无包），再按 selected_source 把对应源的 header/body 及其
    // BCH 校验一起送出去。header 24bit、body 224bit 是 HDMI 音频包的固定长度，
    // 所以这里可以整包并行搬运，不需要逐字节状态机。
    always @* begin
        packet_source = 2'd0;
        packet_header = 24'd0;
        packet_header_ecc = 8'd0;
        packet_body = 224'd0;
        packet_body_ecc = 32'd0;
        if (selected_source == 2'd0 && acr_valid) begin
            packet_source = 2'd0;
            packet_header = acr_header;
            packet_header_ecc = acr_header_ecc;
            packet_body = acr_body;
            packet_body_ecc = acr_body_ecc;
        end else if (selected_source == 2'd1 && info_valid) begin
            packet_source = 2'd1;
            packet_header = info_header;
            packet_header_ecc = info_header_ecc;
            packet_body = info_body;
            packet_body_ecc = info_body_ecc;
        end else if (selected_source == 2'd2 && audio_valid) begin
            packet_source = 2'd2;
            packet_header = audio_header;
            packet_header_ecc = audio_header_ecc;
            packet_body = audio_body;
            packet_body_ecc = audio_body_ecc;
        end
    end
endmodule
