`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 装载前端：把"读卡"和"解析文件"两层接起来（50MHz 系统域）
//
// 两个子模块：
//   sd_sector_replay_buffer：扇区重放。读卡是串行慢的，但 FAT32 扫描和 BMP 解码
//     经常要回头重读同一个扇区（例如目录项、簇链）。重放缓冲把刚读过的扇区
//     缓起来，命中就不用再麻烦卡，减少读卡次数，也让上层逻辑简单。
//   media_ingest_pipeline：真正干活的——扫分区/根目录找 PIC1~PIC5、
//     按簇链取文件、BMP24 解码（含 1280×960 的 2×2 平均缩小）、
//     交给 media_frame_loader 写进 SDRAM。
//
// 对外信号：
//   start 启动一次装载；busy/done 是进度；ingest_error 是主错误码、
//   ingest_detail_error 是细分码（顶层 OSD 上的 D xx 就来自它）；
//   resource_valid/image_complete 是五张图各自的"找到文件/已写完整"；
//   image_ready 是"这张图现在可以给显示用"（配合 EARLY_DISPLAY 提前显示）；
//   image_scale_2x 表示这张图是 1280×960 需要缩小显示。
//   reader_* 一组是向 SD 服务要扇区的握手，app_wr_* 是写 SDRAM 的通路。
// -----------------------------------------------------------------------------
module media_ingest_frontend #(
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer ALLOW_2X_SOURCE = 0,
    parameter integer EARLY_DISPLAY = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output wire                  done,
    output wire [7:0]            ingest_error,
    output wire [7:0]            ingest_detail_error,
    output wire [2:0]            current_image,
    output wire [4:0]            resource_valid,
    output wire [4:0]            image_complete,
    output wire [4:0]            image_scale_2x,
    output wire                  reader_req,
    output wire [31:0]           reader_lba,
    input  wire                  reader_busy,
    input  wire                  reader_valid,
    input  wire [7:0]            reader_byte,
    input  wire [8:0]            reader_byte_index,
    input  wire                  reader_done,
    input  wire [7:0]            reader_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data,
    input  wire                 write_drain_idle,
    output wire [4:0]           image_ready
);
    wire replay_busy;
    wire replay_valid;
    wire [7:0] replay_byte;
    wire [8:0] replay_byte_index;
    wire replay_done;
    wire [7:0] replay_error;
    wire ingest_sector_req;
    wire [31:0] ingest_sector_lba;
    wire ingest_busy;

    assign busy = ingest_busy || replay_busy;

    sd_sector_replay_buffer u_sector_replay (
        .clk(clk), .rst_n(rst_n),
        .sector_req(ingest_sector_req), .sector_lba(ingest_sector_lba),
        .sector_busy(replay_busy), .sector_valid(replay_valid),
        .sector_byte(replay_byte), .sector_byte_index(replay_byte_index),
        .sector_done(replay_done), .sector_error(replay_error),
        .reader_req(reader_req), .reader_lba(reader_lba),
        .reader_busy(reader_busy), .reader_valid(reader_valid),
        .reader_byte(reader_byte), .reader_byte_index(reader_byte_index),
        .reader_done(reader_done), .reader_error(reader_error)
    );

    media_ingest_pipeline #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .STALL_TIMEOUT(STALL_TIMEOUT), .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE), .EARLY_DISPLAY(EARLY_DISPLAY)
    ) u_ingest_pipeline (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(ingest_busy), .done(done),
        .ingest_error(ingest_error), .ingest_detail_error(ingest_detail_error),
        .current_image(current_image),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .image_scale_2x(image_scale_2x),
        .sector_req(ingest_sector_req), .sector_lba(ingest_sector_lba),
        .sector_busy(replay_busy), .sector_valid(replay_valid),
        .sector_byte(replay_byte), .sector_byte_index(replay_byte_index),
        .sector_done(replay_done), .sector_error(replay_error),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data),
        .write_drain_idle(write_drain_idle),.image_ready(image_ready)
    );
endmodule
