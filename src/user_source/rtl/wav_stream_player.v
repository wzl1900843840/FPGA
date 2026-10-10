`timescale 1ns/1ps

// R3'-A: stream real audio content from the TF card and feed it into the
// existing HDMI audio chain (docs/29 rev: "what actually wins"). This module
// sits between the SD sector-read infrastructure and the PCM sample
// interface, using a dual-port BRAM circular buffer to absorb the ~12.5x
// rate mismatch between TF reads (~1.2 MB/s burst) and audio consumption
// (96 KB/s at 48 kHz 16-bit mono).
//
// Architecture:
//   TF sector bytes (mem_clk domain, byte-serial)
//     -> pair into 16-bit samples -> write into BRAM circular buffer
//   Audio sample ticks (pixel_clk domain, ~48 kHz)
//     -> read from BRAM -> output on valid/ready PCM interface
//
// The write side uses a sector-level state machine: issue one sector read,
// fill 256 samples (512 bytes), then issue the next. The read side consumes
// at the audio sample rate. Pointer crossing uses gray-coded 2FF sync (the
// established idiom). Buffer underflow outputs silence (zeros) with
// sample_valid still asserted, so the downstream HDMI chain never stalls.
//
// Data format: raw 16-bit signed little-endian PCM, 48 kHz mono. The PC
// tool (tools/make_audio_corpus.py) converts any WAV to this format before
// writing to the TF card. Endianness: TF bytes arrive LSB first.
//
// 模块职责：把 TF 卡上的裸 PCM 流成 48kHz 音频样本，喂给 HDMI 音频链。
// 位置：上游是 SD 扇区读取服务（sd_media_service 侧的 req/lba/byte 接口），
//       下游是 media_hdmi_audio_bridge 的 PCM 样本接口。
// 时钟域：写侧 wr_clk = 50MHz 系统域（SD SPI 引擎时钟），读侧 rd_clk = 25MHz 像素域，
//       两侧通过 4096×16bit 双口 BRAM 环形缓冲 + Gray 指针跨域同步。
// 为什么需要缓冲：TF 是突发式读取（约 1.2MB/s，一整扇区 512 字节一次到），
//       音频是匀速消费（48kHz×16bit = 96KB/s），瞬时速率差约 12.5 倍，
//       没有缓冲就会在每次换扇区时断音。
// 输入约定：play_enable 是电平使能；start_lba/total_sectors 指定连续物理扇区范围
//       （必须由 PC 工具保证 PCM 连续存放，本模块不做簇链跟踪）。
// 输出约定：sample_valid/sample_ready 握手输出样本；stream_end 表示数据放完；
//       buffer_low 供 OSD 显示"缓冲偏低"。
// 关键设计：
//   1) 指针多一位表示回卷（wrapping），Gray 码必须在源域生成后再跨域，
//      这样对面域采样到的指针只会"旧一拍"，不会读到撕裂的二进制值。
//   2) 欠载（缓冲空）时输出 0 并仍然拉高 sample_valid，让下游 HDMI 链
//      永远不断流，避免接收端因长时间无包而失步。
//   3) 只有"尾部样本也排空"（含 valid 尚未握手的数据）才置 stream_end。
module wav_stream_player #(
    parameter integer ADDR_WIDTH = 12,         // 4096 x 16-bit = 8 KB
    parameter integer SAMPLES_PER_SECTOR = 256 // 512 bytes / 2
) (
    // write side: mem_clk domain (SD SPI engine clock)
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // level: stream active
    input  wire [31:0] start_lba,          // first data sector (after WAV header)
    input  wire [31:0] total_sectors,      // audio data extent in sectors
    output wire        sd_req,             // request a sector read
    output reg  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_valid,           // one byte per valid pulse
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,      // 0..511 within sector
    input  wire        sd_done,
    input  wire [7:0]  sd_error,

    // read side: pixel_clk domain (audio chain clock)
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // ~48 kHz pulse: consume one sample
    output wire signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // from downstream (always 1 in our chain)

    // status (read side)
    output reg  [31:0] sample_counter,     // samples consumed (for OSD)
    output wire        stream_active,      // play_enable && not ended
    output wire        stream_end,         // all data consumed
    output wire        buffer_low          // < 25% remaining (for OSD/status)
);
    // ===== 环形缓冲与跨域指针 =====
    // 二进制指针多一位表示回卷；Gray 编码必须在源域生成。
    // used_wr/used_rd 用"指针差"算占用深度：写侧用同步过来的读指针，
    // 读侧用同步过来的写指针，两边各自判断自己的水位，不需要互相等待。
    localparam integer DEPTH=1<<ADDR_WIDTH;
    reg [15:0] buffer [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wr_ptr,rd_ptr,wr_gray,rd_gray;
    reg [ADDR_WIDTH:0] rd_gray_sync1,rd_gray_sync2,wr_gray_sync1,wr_gray_sync2;
    reg play_sync1,play_sync2,end_sync1,end_sync2;
    reg [31:0] sectors_read;
    reg [7:0] low_byte;
    reg [2:0] state;
    reg started;
    reg [15:0] ram_sample;
    reg sample_has_data;
    localparam IDLE=0,WAIT_SPACE=1,REQUEST=2,FILL=3,FINISHED=4;
    // Gray→二进制解码：高位直接取，低位逐位异或还原，只用于算深度差。
    function [ADDR_WIDTH:0] binary;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            binary[ADDR_WIDTH]=gray[ADDR_WIDTH];
            for(i=ADDR_WIDTH-1;i>=0;i=i-1) binary[i]=binary[i+1]^gray[i];
        end
    endfunction
    wire [ADDR_WIDTH:0] used_wr=wr_ptr-binary(rd_gray_sync2);
    wire [ADDR_WIDTH:0] used_rd=binary(wr_gray_sync2)-rd_ptr;
    assign sd_req=state==REQUEST;
    // 状态输出属于读域；必须等尾部样本（包括 valid 尚未握手的数据）排空。
    assign stream_end=play_sync2 && end_sync2 && used_rd==0 && !sample_valid;
    assign stream_active=play_sync2 && !stream_end;
    assign buffer_low=used_rd < DEPTH/4;
    // ===== 状态输出与取数条件 =====
    // take_tick：本拍可以推进一个样本（采样节拍到、旧样本已被取走、且未播完）；
    // take_data：真正从 BRAM 读数据（要求已经启动且缓冲非空），否则输出静音 0。
    wire take_tick=play_sync2 && sample_tick && (!sample_valid || sample_ready) && !stream_end;
    wire take_data=take_tick && started && used_rd!=0;
    // RAM 数据端不加异步复位，才能映射到片上双口 BRAM。
    // valid/has_data 复位保证上电和欠载时输出静音，背压时保持样本。
    always @(posedge wr_clk)
        if(wr_rst_n && state==FILL && sd_valid && play_enable && sd_byte_index[0] && used_wr<DEPTH)
            buffer[wr_ptr[ADDR_WIDTH-1:0]]<={sd_byte,low_byte};
    always @(posedge rd_clk)
        if(take_data) ram_sample<=buffer[rd_ptr[ADDR_WIDTH-1:0]];
    assign sample_out=sample_has_data ? ram_sample : 16'd0;
    // ===== 写侧：扇区级状态机 =====
    // IDLE 等使能 → WAIT_SPACE 等缓冲腾出整扇区空间（避免读到一半没地方放）
    // → REQUEST 拉起 sd_req 请一个扇区 → FILL 收 512 字节（每 2 字节拼成 1 个
    // 16bit 小端样本写入 BRAM）→ 扇区收完就推进 LBA 回到 WAIT_SPACE，
    // 直到读满 total_sectors 或出错或使能撤销，进入 FINISHED。
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin
            state<=IDLE;wr_ptr<=0;wr_gray<=0;rd_gray_sync1<=0;rd_gray_sync2<=0;
            sectors_read<=0;sd_lba<=0;low_byte<=0;
        end else begin
            rd_gray_sync1<=rd_gray;rd_gray_sync2<=rd_gray_sync1;
            if(!play_enable && state!=FILL && state!=REQUEST) begin
                state<=IDLE;wr_ptr<=0;wr_gray<=0;sectors_read<=0;
            end else case(state)
                IDLE: if(play_enable && start_lba!=0 && total_sectors!=0) begin
                    sd_lba<=start_lba;state<=WAIT_SPACE;
                end
                WAIT_SPACE: if(used_wr<=DEPTH-SAMPLES_PER_SECTOR && !sd_busy)
                    state<=REQUEST;
                REQUEST: if(!sd_busy) state<=FILL;
                FILL: begin
                    if(sd_valid && play_enable) begin
                        if(!sd_byte_index[0]) low_byte<=sd_byte;
                        else if(used_wr<DEPTH) begin
                            wr_ptr<=wr_ptr+1'b1;
                            wr_gray<=((wr_ptr+1'b1)>>1)^(wr_ptr+1'b1);
                        end
                    end
                    if(sd_done) begin
                        sectors_read<=sectors_read+1'b1;
                        sd_lba<=sd_lba+1'b1;
                        state<=(sd_error!=0 || sectors_read+1>=total_sectors || !play_enable)
                            ? FINISHED : WAIT_SPACE;
                    end
                end
                FINISHED: ;
                default: state<=IDLE;
            endcase
        end
    end
    // ===== 读侧：按采样节拍消费，欠载补静音 =====
    // started 的作用是"等缓冲先攒够一个扇区再开声"，避免刚启动时反复欠载；
    // 之后每来一个 sample_tick 就产出一个样本，缓冲空则 sample_has_data=0，
    // 输出 0（静音）但 sample_valid 照常拉高，下游不会因缺样本而卡住。
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin
            rd_ptr<=0;rd_gray<=0;wr_gray_sync1<=0;wr_gray_sync2<=0;
            play_sync1<=0;play_sync2<=0;end_sync1<=0;end_sync2<=0;
            sample_valid<=0;sample_has_data<=0;sample_counter<=0;started<=0;
        end else begin
            wr_gray_sync1<=wr_gray;wr_gray_sync2<=wr_gray_sync1;
            play_sync1<=play_enable;play_sync2<=play_sync1;
            end_sync1<=state==FINISHED;end_sync2<=end_sync1;
            if(sample_valid && sample_ready) sample_valid<=0;
            if(!play_sync2) begin
                rd_ptr<=0;rd_gray<=0;sample_valid<=0;sample_counter<=0;started<=0;
            end else begin
                if(used_rd>=SAMPLES_PER_SECTOR || end_sync2) started<=1;
                if(sample_tick && (!sample_valid || sample_ready) && !stream_end) begin
                    sample_valid<=1;
                    sample_has_data<=0;
                    if(started && used_rd!=0) begin
                        sample_has_data<=1;
                        rd_ptr<=rd_ptr+1'b1;
                        rd_gray<=((rd_ptr+1'b1)>>1)^(rd_ptr+1'b1);
                        sample_counter<=sample_counter+1'b1;
                    end
                end
            end
        end
    end
endmodule
