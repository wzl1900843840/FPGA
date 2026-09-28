`timescale 1ns/1ps

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

    assign owner_reader = init_ready;
    assign sd_cs_n = owner_reader ? reader_cs_n : init_cs_n;
    assign sd_sclk = owner_reader ? reader_sclk : init_sclk;
    assign sd_mosi = owner_reader ? reader_mosi : init_mosi;

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
