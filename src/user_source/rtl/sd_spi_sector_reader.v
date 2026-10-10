`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// SD卡单扇区读取器（CMD17）
//
// 干什么：收到 sector_req 后，按 sector_lba 读一个 512 字节扇区，边读边算 CRC16，
//         每读到一个字节就发一次 sector_valid + sector_byte + 序号，
//         最后 sector_done 一拍；出错时 sector_error 给出错误码并跳过数据段。
//
// 状态机是一条"请求/等待"的直线，每个字节都要经过 字节引擎(sd_spi_byte_engine)：
//   ST_IDLE       等 sector_req；此时先检查卡是否初始化好（没好直接报 ERR_NOT_READY）
//   ST_PRE_REQ/WAIT  先发一个 0xFF 空字节，给卡留出准备时间
//   ST_CMD_REQ/WAIT  依次发 6 个字节：0x51(CMD17) + 4字节参数 + CRC7
//   ST_R1_REQ/WAIT   轮询 R1 响应：bit7=0 表示响应到了；0x00 才算成功
//   ST_TOKEN_REQ/WAIT 轮询数据起始 token 0xFE；期间卡可能回 0xFF（忙）
//   ST_DATA_REQ/WAIT 收 512 个数据字节，同时更新 CRC16
//   ST_CRC_H/L_REQ/WAIT 收卡发来的 2 字节 CRC，和本地算的比对
//   ST_POST_REQ/WAIT 再发一个空字节收尾，然后 sector_done
//
// 地址规则：SDHC/SDXC 卡的参数就是块地址(LBA)；老卡(标准容量)要左移9位变成字节地址。
// CRC16 用的是 SD 规定的多项式 x^16+x^12+x^5+1（0x1021）。
// 每个 *_REQ/*_WAIT 成对出现，是因为字节引擎一次只能收发一个字节，需要握手。
// -----------------------------------------------------------------------------
module sd_spi_sector_reader #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer MAX_R1_BYTES = 16,
    parameter integer MAX_TOKEN_BYTES = 4096,
    parameter CHECK_DATA_CRC = 1'b1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init_ready,
    input  wire        card_high_capacity,
    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output reg         sector_done,
    output reg         sector_valid,
    output reg  [7:0]  sector_byte,
    output reg  [8:0]  sector_byte_index,
    output reg  [7:0]  sector_error,
    output reg  [7:0]  last_r1,
    output wire        sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    // 错误码：调用方只看 sector_error 是否非0，细分码便于定位卡在哪一步
    localparam ERR_NONE          = 8'h00;
    localparam ERR_R1_TIMEOUT    = 8'h01;
    localparam ERR_R1_STATUS     = 8'h02;
    localparam ERR_TOKEN_TIMEOUT = 8'h03;
    localparam ERR_BAD_TOKEN     = 8'h04;
    localparam ERR_DATA_CRC      = 8'h05;
    localparam ERR_NOT_READY     = 8'h06;

    // 状态机：每个"发字节"和"等字节"是一对，因为字节引擎一次只处理一个字节
    localparam ST_IDLE       = 5'd0;
    localparam ST_PRE_REQ    = 5'd1;
    localparam ST_PRE_WAIT   = 5'd2;
    localparam ST_CMD_REQ    = 5'd3;
    localparam ST_CMD_WAIT   = 5'd4;
    localparam ST_R1_REQ     = 5'd5;
    localparam ST_R1_WAIT    = 5'd6;
    localparam ST_TOKEN_REQ  = 5'd7;
    localparam ST_TOKEN_WAIT = 5'd8;
    localparam ST_DATA_REQ   = 5'd9;
    localparam ST_DATA_WAIT  = 5'd10;
    localparam ST_CRC_H_REQ  = 5'd11;
    localparam ST_CRC_H_WAIT = 5'd12;
    localparam ST_CRC_L_REQ  = 5'd13;
    localparam ST_CRC_L_WAIT = 5'd14;
    localparam ST_POST_REQ   = 5'd15;
    localparam ST_POST_WAIT  = 5'd16;

    reg [4:0] state;
    reg [2:0] cmd_byte_index;
    reg [31:0] command_argument;
    reg [8:0] data_count;
    reg [15:0] data_crc;
    reg [7:0] received_crc_high;
    integer r1_poll_count;
    integer token_poll_count;

    reg byte_start;
    reg [7:0] byte_tx;
    wire byte_busy;
    wire byte_done;
    wire [7:0] byte_rx;

    // CS 只在空闲和收尾时为高；发命令/收数据期间必须保持拉低
    assign sector_busy = (state != ST_IDLE);
    assign sd_cs_n = (state == ST_IDLE || state == ST_PRE_REQ ||
                      state == ST_PRE_WAIT || state == ST_POST_REQ ||
                      state == ST_POST_WAIT);

    // 命令字节：第0字节固定 0x51 = CMD17(读单块)，后面4字节是参数(地址)
    function [7:0] command_byte;
        input [2:0] index;
        begin
            case (index)
                3'd0: command_byte = 8'h51;
                3'd1: command_byte = command_argument[31:24];
                3'd2: command_byte = command_argument[23:16];
                3'd3: command_byte = command_argument[15:8];
                3'd4: command_byte = command_argument[7:0];
                default: command_byte = 8'hff;
            endcase
        end
    endfunction

    // SD 规范规定的 CRC16：多项式 0x1021，逐位串行计算
    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer i;
        reg [15:0] crc_work;
        begin
            crc_work = crc_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc_work[15] ^ data_in[7-i])
                    crc_work = {crc_work[14:0], 1'b0} ^ 16'h1021;
                else
                    crc_work = {crc_work[14:0], 1'b0};
            end
            crc16_byte = crc_work;
        end
    endfunction

    sd_spi_byte_engine #(
        .CLK_DIV(SPI_CLK_DIV)
    ) u_byte_engine (
        .clk(clk), .rst_n(rst_n), .start(byte_start), .tx_byte(byte_tx),
        .miso(sd_miso), .busy(byte_busy), .done(byte_done),
        .rx_byte(byte_rx), .sclk(sd_sclk), .mosi(sd_mosi)
    );

    // 出错统一走这里：记下错误码，然后照常进收尾状态，保证 CS 拉高、总线释放
    task finish_with_error;
        input [7:0] code;
        begin
            sector_error <= code;
            state <= ST_POST_REQ;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            cmd_byte_index    <= 3'd0;
            command_argument  <= 32'd0;
            data_count        <= 9'd0;
            data_crc          <= 16'd0;
            received_crc_high <= 8'd0;
            r1_poll_count     <= 0;
            token_poll_count  <= 0;
            byte_start        <= 1'b0;
            byte_tx           <= 8'hff;
            sector_done       <= 1'b0;
            sector_valid      <= 1'b0;
            sector_byte       <= 8'd0;
            sector_byte_index <= 9'd0;
            sector_error      <= ERR_NONE;
            last_r1           <= 8'hff;
        end else begin
            byte_start   <= 1'b0;
            sector_done  <= 1'b0;
            sector_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (sector_req) begin
                        sector_error <= ERR_NONE;
                        last_r1 <= 8'hff;
                        if (!init_ready) begin
                            sector_error <= ERR_NOT_READY;
                            sector_done <= 1'b1;
                        end else begin
                            // SDHC/SDXC 直接给块号；标准容量卡要换算成字节地址
                            command_argument <= card_high_capacity ? sector_lba : (sector_lba << 9);
                            cmd_byte_index <= 3'd0;
                            r1_poll_count <= 0;
                            token_poll_count <= 0;
                            data_count <= 9'd0;
                            data_crc <= 16'd0;
                            state <= ST_PRE_REQ;
                        end
                    end
                end
                ST_PRE_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_PRE_WAIT;
                end
                ST_PRE_WAIT: if (byte_done) begin
                    byte_tx <= command_byte(3'd0);
                    state <= ST_CMD_REQ;
                end
                ST_CMD_REQ: if (!byte_busy) begin
                    byte_start <= 1'b1;
                    state <= ST_CMD_WAIT;
                end
                ST_CMD_WAIT: if (byte_done) begin
                    if (cmd_byte_index == 3'd5) begin
                        r1_poll_count <= 0;
                        state <= ST_R1_REQ;
                    end else begin
                        cmd_byte_index <= cmd_byte_index + 1'b1;
                        byte_tx <= command_byte(cmd_byte_index + 1'b1);
                        state <= ST_CMD_REQ;
                    end
                end
                ST_R1_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_R1_WAIT;
                end
                ST_R1_WAIT: if (byte_done) begin
                    if (!byte_rx[7]) begin          // bit7=0：卡开始回应了
                        last_r1 <= byte_rx;
                        if (byte_rx == 8'h00) begin  // R1=0 表示命令被接受
                            token_poll_count <= 0;
                            state <= ST_TOKEN_REQ;
                        end else begin
                            finish_with_error(ERR_R1_STATUS);   // 卡回了错误状态位
                        end
                    end else if (r1_poll_count == MAX_R1_BYTES-1) begin
                        finish_with_error(ERR_R1_TIMEOUT);      // 一直0xFF：没回应
                    end else begin
                        r1_poll_count <= r1_poll_count + 1;
                        state <= ST_R1_REQ;
                    end
                end
                ST_TOKEN_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_TOKEN_WAIT;
                end
                ST_TOKEN_WAIT: if (byte_done) begin
                    if (byte_rx == 8'hfe) begin     // 数据起始 token
                        data_count <= 9'd0;
                        data_crc <= 16'd0;
                        state <= ST_DATA_REQ;
                    end else if (byte_rx != 8'hff) begin
                        finish_with_error(ERR_BAD_TOKEN);    // 既不是token也不是忙
                    end else if (token_poll_count == MAX_TOKEN_BYTES-1) begin
                        finish_with_error(ERR_TOKEN_TIMEOUT);
                    end else begin
                        token_poll_count <= token_poll_count + 1;
                        state <= ST_TOKEN_REQ;
                    end
                end
                ST_DATA_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (byte_done) begin
                    // 每收到一个字节就吐给调用方一拍，同时累加 CRC16
                    sector_byte <= byte_rx;
                    sector_byte_index <= data_count;
                    sector_valid <= 1'b1;
                    data_crc <= crc16_byte(data_crc, byte_rx);
                    if (data_count == 9'd511)
                        state <= ST_CRC_H_REQ;
                    else begin
                        data_count <= data_count + 1'b1;
                        state <= ST_DATA_REQ;
                    end
                end
                ST_CRC_H_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_CRC_H_WAIT;
                end
                ST_CRC_H_WAIT: if (byte_done) begin
                    received_crc_high <= byte_rx;
                    state <= ST_CRC_L_REQ;
                end
                ST_CRC_L_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_CRC_L_WAIT;
                end
                ST_CRC_L_WAIT: if (byte_done) begin
                    // 卡发来的2字节CRC与本地计算值比对（可参数关掉，便于仿真）
                    if (CHECK_DATA_CRC && {received_crc_high, byte_rx} != data_crc)
                        sector_error <= ERR_DATA_CRC;
                    state <= ST_POST_REQ;
                end
                ST_POST_REQ: if (!byte_busy) begin
                    byte_tx <= 8'hff;
                    byte_start <= 1'b1;
                    state <= ST_POST_WAIT;
                end
                ST_POST_WAIT: if (byte_done) begin
                    sector_done <= 1'b1;   // 一次读扇区完成（成功或失败都发这一拍）
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
