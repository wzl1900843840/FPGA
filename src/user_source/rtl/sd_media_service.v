`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// SD卡服务入口：一块卡、两个客户，共用一组SPI引脚
//
// 两个客户：
//   u_init  (sd_spi_init)          —— 上电初始化：慢时钟(INIT_SPI_CLK_DIV)、
//                                    CMD0/CMD8/ACMD41 流程，拿到卡类型和OCR；
//   u_reader(sd_spi_sector_reader) —— 正常读扇区：快时钟(SPI_CLK_DIV)。
//
// 为什么分成两个模块：初始化阶段SD协议要求很慢的时钟（约390.625kHz），
// 而读扇区可以跑到6.25/12.5MHz。同一模块里切换时钟分频容易出错，分开更清楚。
//
// 谁在驱动SPI引脚：owner_reader = init_ready。初始化没完成前由 u_init 驱动，
// 完成后整组 cs/sclk/mosi 交给 u_reader，两者不会同时输出。
//
// 扇区请求只有一个入口 sector_req/lba：顶层用它轮流服务"图片装载"和"音频播放"
// （谁用由顶层的 audio_owner 决定），本模块不关心谁在请求。
// 返回协议：busy 期间每拍给出一个字节 sector_byte + 序号 sector_byte_index，
//          结束时 sector_done 一拍，错误码 sector_error 非0表示本次失败。
// -----------------------------------------------------------------------------
module sd_media_service #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer INIT_SPI_CLK_DIV = 64,
    parameter integer POWER_UP_BYTES = 10,
    parameter integer MAX_RESPONSE_BYTES = 16,
    parameter integer MAX_ACMD41_ATTEMPTS = 2048,
    // Post-reset power-ramp wait before CMD0. Silicon needs the full 100 ms
    // for large SDHC/SDXC cards; testbenches override this down to a few
    // hundred cycles so their watchdogs still bound the run.
    parameter integer INIT_STARTUP_DELAY_CYCLES = 4000000,
    parameter integer MAX_R1_BYTES = 16,
    parameter integer MAX_TOKEN_BYTES = 4096,
    parameter CHECK_DATA_CRC = 1'b1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init_start,
    output wire        init_busy,
    output wire        init_done,
    output wire        init_ready,
    output wire [7:0]  init_error,
    output wire        card_high_capacity,
    output wire [31:0] card_ocr,
    output wire        owner_reader,

    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output wire        sector_done,
    output wire        sector_valid,
    output wire [7:0]  sector_byte,
    output wire [8:0]  sector_byte_index,
    output wire [7:0]  sector_error,

    output wire        sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);
    wire init_cs_n, init_sclk, init_mosi;
    wire reader_cs_n, reader_sclk, reader_mosi;

    // 引脚所有权：初始化完成后（init_ready）交给读扇区模块，二者互斥
    assign owner_reader = init_ready;
    assign sd_cs_n = owner_reader ? reader_cs_n : init_cs_n;
    assign sd_sclk = owner_reader ? reader_sclk : init_sclk;
    assign sd_mosi = owner_reader ? reader_mosi : init_mosi;

    // 初始化：慢时钟 + 上电等待 + CMD0/CMD8/ACMD41，产出卡类型/OCR/错误码
    sd_spi_init #(
        .SPI_CLK_DIV(INIT_SPI_CLK_DIV), .POWER_UP_BYTES(POWER_UP_BYTES),
        .MAX_RESPONSE_BYTES(MAX_RESPONSE_BYTES),
        .MAX_ACMD41_ATTEMPTS(MAX_ACMD41_ATTEMPTS),
        .STARTUP_DELAY_CYCLES(INIT_STARTUP_DELAY_CYCLES)
    ) u_init (
        .clk(clk), .rst_n(rst_n), .init_start(init_start),
        .init_busy(init_busy), .init_done(init_done), .init_ready(init_ready),
        .error_code(init_error), .card_high_capacity(card_high_capacity),
        .ocr(card_ocr), .last_cmd(), .last_r1(), .acmd41_attempts(),
        .sd_cs_n(init_cs_n), .sd_sclk(init_sclk), .sd_mosi(init_mosi),
        .sd_miso(sd_miso)
    );

    // 正常读扇区：按 LBA 发 CMD17，校验 token 与 CRC，逐字节吐出 512 字节
    sd_spi_sector_reader #(
        .SPI_CLK_DIV(SPI_CLK_DIV), .MAX_R1_BYTES(MAX_R1_BYTES),
        .MAX_TOKEN_BYTES(MAX_TOKEN_BYTES), .CHECK_DATA_CRC(CHECK_DATA_CRC)
    ) u_reader (
        .clk(clk), .rst_n(rst_n), .init_ready(init_ready),
        .card_high_capacity(card_high_capacity), .sector_req(sector_req),
        .sector_lba(sector_lba), .sector_busy(sector_busy),
        .sector_done(sector_done), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_error(sector_error), .last_r1(),
        .sd_cs_n(reader_cs_n), .sd_sclk(reader_sclk), .sd_mosi(reader_mosi),
        .sd_miso(sd_miso)
    );
endmodule
