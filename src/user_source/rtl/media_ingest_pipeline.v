`timescale 1ns/1ps

module media_ingest_pipeline #(
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
    output reg                   done,
    output reg  [7:0]            ingest_error,
    output reg  [7:0]            ingest_detail_error,
    output reg  [1:0]            current_image,
    output wire [3:0]            resource_valid,
    output wire [3:0]            image_complete,
    output reg  [3:0]            image_scale_2x,

    output wire                  sector_req,
    output wire [31:0]           sector_lba,
    input  wire                  sector_busy,
    input  wire                  sector_valid,
    input  wire [7:0]            sector_byte,
    input  wire [8:0]            sector_byte_index,
    input  wire                  sector_done,
    input  wire [7:0]            sector_error,

    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data,
    input  wire                 write_drain_idle,
    output wire [3:0]           image_ready
);
    localparam integer IMAGE_WORDS = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam ERR_NONE   = 8'h00;
    localparam ERR_SCAN   = 8'h80;
    localparam ERR_FILE   = 8'h82;
    localparam ERR_BMP    = 8'h83;
    localparam ERR_MEMORY = 8'h84;

    localparam ST_IDLE      = 3'd0;
    localparam ST_SCAN      = 3'd1;
    localparam ST_FILE_START= 3'd2;
    localparam ST_FILE      = 3'd3;
    localparam ST_FAIL_WAIT = 3'd4;
    localparam ST_DRAIN     = 3'd5;

    reg [2:0] state;
    reg scan_start;
    reg file_start;
    reg load_start;
    reg load_finished;
    reg [3:0] verified_images;
    reg [7:0] drain_count;
    assign image_ready=EARLY_DISPLAY ? verified_images : image_complete;
    // 解码/SDRAM写完不等于文件FAT尾链校验完成；两端排空后才开下一文件。

    wire scan_busy;
    wire scan_done;
    wire [7:0] scan_error;
    wire [7:0] sectors_per_cluster;
    wire [31:0] fat_start_lba;
    wire [31:0] data_start_lba;
    wire [31:0] max_cluster;
    wire [31:0] resource0_cluster, resource1_cluster;
    wire [31:0] resource2_cluster, resource3_cluster;
    wire [31:0] resource0_size, resource1_size;
    wire [31:0] resource2_size, resource3_size;
    wire scan_sector_req;
    wire [31:0] scan_sector_lba;

    wire file_busy;
    wire file_done;
    wire file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0] file_error;
    wire file_sector_req;
    wire [31:0] file_sector_lba;
    wire [31:0] selected_cluster;
    wire [31:0] selected_size;

    wire pixel_valid;
    wire [23:0] pixel_rgb;
    wire frame_commit;
    wire bmp_done;
    wire [7:0] bmp_error;
    wire source_scale_2x;
    wire source_top_down;
    reg [1:0] retry_count;
    wire load_busy;
    wire load_done;
    wire [7:0] memory_error;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) load_finished<=0;
        else if(state==ST_FILE_START) load_finished<=0;
        else if(load_done) load_finished<=1;

    assign busy = state != ST_IDLE;
    assign sector_req = scan_sector_req | file_sector_req;
    assign sector_lba = scan_sector_req ? scan_sector_lba : file_sector_lba;

    assign selected_cluster = current_image == 2'd0 ? resource0_cluster :
                              current_image == 2'd1 ? resource1_cluster :
                              current_image == 2'd2 ? resource2_cluster : resource3_cluster;
    assign selected_size = current_image == 2'd0 ? resource0_size :
                           current_image == 2'd1 ? resource1_size :
                           current_image == 2'd2 ? resource2_size : resource3_size;

    fat32_volume_scanner u_volume_scanner (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy),
        .scan_done(scan_done), .fs_error(scan_error), .partition_lba(),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    fat32_file_streamer u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(file_start),
        .first_cluster(selected_cluster), .file_size(selected_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset), .fs_error(file_error),
        .sector_req(file_sector_req), .sector_lba(file_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    bmp24_decoder #(
        .EXPECTED_WIDTH(IMAGE_WIDTH), .EXPECTED_HEIGHT(IMAGE_HEIGHT),
        .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE)
    ) u_bmp_decoder (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .file_size(selected_size),
        .file_valid(file_valid), .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_end(file_done), .upstream_error(file_error), .header_accepted(),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .pixel_x(), .pixel_y(),
        .frame_commit(frame_commit), .bmp_done(bmp_done), .bmp_error(bmp_error),
        .top_down(source_top_down), .pixel_offset(), .row_stride(),
        .source_scale_2x(source_scale_2x)
    );

    media_frame_loader #(
        .ADDR_WIDTH(ADDR_WIDTH), .IMAGE_WORDS(IMAGE_WORDS),
        .FIFO_DEPTH(FIFO_DEPTH), .STALL_TIMEOUT(STALL_TIMEOUT), .DRAIN_ON_ERROR(EARLY_DISPLAY)
    ) u_frame_loader (
        .clk(clk), .rst_n(rst_n), .load_start(load_start), .image_index(current_image),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .source_top_down(source_top_down), .frame_commit(frame_commit),
        .decode_error(bmp_error), .load_busy(load_busy), .load_done(load_done),
        .image_complete(image_complete), .memory_error(memory_error),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;
            ingest_error <= ERR_NONE;
            ingest_detail_error <= ERR_NONE;
            current_image <= 2'd0; retry_count<=0;
            image_scale_2x <= 4'd0;
            verified_images<=0;drain_count<=0;
        end else begin
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;

            case (state)
                ST_IDLE: if (start) begin
                    ingest_error <= ERR_NONE;
                    ingest_detail_error <= ERR_NONE;
                    current_image <= 2'd0; retry_count<=0;
                    image_scale_2x <= 4'd0;
                    verified_images<=0;drain_count<=0;
                    scan_start <= 1'b1;
                    state <= ST_SCAN;
                end
                ST_SCAN: if (scan_done) begin
                    if (scan_error != 0 && !(scan_error==8'h22 && resource_valid!=0)) begin
                        ingest_error <= ERR_SCAN;
                        ingest_detail_error <= scan_error;
                        state <= ST_FAIL_WAIT;
                    end else begin
                        current_image <= 2'd0; retry_count<=0;
                        state <= ST_FILE_START;
                    end
                end
                ST_FILE_START: if(!resource_valid[current_image]) begin
                    if(current_image==3) begin done<=1;state<=ST_IDLE;end
                    else current_image<=current_image+1'b1;
                end else begin
                    file_start <= 1'b1;
                    load_start <= 1'b1;
                    state <= ST_FILE;
                end
                ST_FILE: if ((load_done || load_finished) && !file_busy) begin
                    if (file_error != 0) begin
                        ingest_error <= ERR_FILE;
                        ingest_detail_error <= file_error;
                        state <= ST_FAIL_WAIT;
                    end else if (bmp_error != 0) begin
                        ingest_error <= ERR_BMP;
                        ingest_detail_error <= bmp_error;
                        state <= ST_FAIL_WAIT;
                    end else if (memory_error != 0) begin
                        ingest_error <= ERR_MEMORY;
                        ingest_detail_error <= memory_error;
                        state <= ST_FAIL_WAIT;
                    end else if (EARLY_DISPLAY) begin
                        // Publish after file/FAT validation and the write CDC
                        // have both finished; never expose a partial frame.
                        image_scale_2x[current_image] <= source_scale_2x;
                        drain_count<=0;state<=ST_DRAIN;
                    end else if (current_image == 2'd3) begin
                        image_scale_2x[current_image] <= source_scale_2x;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        image_scale_2x[current_image] <= source_scale_2x;
                        current_image <= current_image + 1'b1; retry_count<=0;
                        state <= ST_FILE_START;
                    end
                end
                ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    // 文件读取排空后有限重试；坏图跳过，已完成 bank 不受影响。
                    if(ingest_error==ERR_SCAN) begin done<=1;state<=ST_IDLE;end
                    else if(retry_count<1) begin retry_count<=retry_count+1'b1;state<=ST_FILE_START;end
                    else if(current_image==3) begin done<=1;state<=ST_IDLE;end
                    else begin current_image<=current_image+1'b1;retry_count<=0;state<=ST_FILE_START;end
                end
                ST_DRAIN: if(write_drain_idle) begin
                    if(drain_count==255) begin
                        verified_images[current_image]<=1'b1;retry_count<=0;
                        if(current_image==3) begin done<=1;state<=ST_IDLE;end
                        else begin current_image<=current_image+1'b1;state<=ST_FILE_START;end
                    end else drain_count<=drain_count+1'b1;
                end else drain_count<=0;
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
